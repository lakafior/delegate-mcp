import Foundation

public struct DelegateRequest: Sendable {
    public var prompt: String
    public var system: String?
    /// `provider/model` albo samo ID modelu.
    public var model: String?
    public var task: String?
    public var temperature: Double?
    public var maxTokens: Int?
    /// `false`: tylko wskazany model, bez przechodzenia do następnych.
    public var allowFallback: Bool
    /// `false`: zablokuj, jeśli w prompcie lub system prompt wykryto potencjalny klucz API/sekret.
    public var allowSecrets: Bool
    /// `true`: wymuś format odpowiedzi jako czysty JSON.
    public var jsonMode: Bool
    /// Jak wrażliwe są dane; serwer odrzuca dostawców spoza dozwolonych regionów.
    public var sensitivity: Sensitivity
    /// Ścieżki plików tekstowych, które serwer dokleja do promptu (`FileAttachments`).
    public var files: [String]
    /// Ścieżka, pod którą serwer zapisuje odpowiedź (`OutputFile`); Claude dostaje wtedy tylko podgląd.
    public var outputFile: String?

    public init(prompt: String, system: String? = nil, model: String? = nil, task: String? = nil,
                temperature: Double? = nil, maxTokens: Int? = nil, allowFallback: Bool = true,
                allowSecrets: Bool = false, jsonMode: Bool = false, sensitivity: Sensitivity = .public,
                files: [String] = [], outputFile: String? = nil) {
        self.prompt = prompt
        self.system = system
        self.model = model
        self.task = task
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.allowFallback = allowFallback
        self.allowSecrets = allowSecrets
        self.jsonMode = jsonMode
        self.sensitivity = sensitivity
        self.files = files
        self.outputFile = outputFile
    }
}

public struct Candidate: Sendable, Equatable {
    public var provider: ProviderConfig
    public var model: ModelConfig
    public var ref: String { "\(provider.id)/\(model.id)" }
}

/// Zmiana jednego modelu; pola `nil` zostają bez zmian. Kategoria i kwoty wykluczają się.
public struct ModelUpdate: Sendable {
    public var id: String
    public var tags: [String]?
    public var cost: String?
    public var priceIn: Double?
    public var priceOut: Double?
    public var note: String?

    public init(id: String, tags: [String]? = nil, cost: String? = nil,
                priceIn: Double? = nil, priceOut: Double? = nil, note: String? = nil) {
        self.id = id
        self.tags = tags
        self.cost = cost
        self.priceIn = priceIn
        self.priceOut = priceOut
        self.note = note
    }

    func apply(to m: inout ModelConfig) {
        if let tags {
            var seen = Set<String>()
            m.tags = tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        if priceIn != nil || priceOut != nil {
            m.priceIn = priceIn
            m.priceOut = priceOut
            m.cost = nil
        } else if let cost {
            m.cost = cost
            m.priceIn = nil
            m.priceOut = nil
        }
        if let note { m.note = note.isEmpty ? nil : note }
    }
}

public enum ProviderStatus: Sendable, Equatable {
    case ready
    case disabled
    case missingKey(String)
    case unavailable(String)

    /// Wspólna reguła dla narzędzi MCP i GUI.
    public static func evaluate(_ p: ProviderConfig, hasKey: Bool, onDevice: OnDeviceAvailability) -> ProviderStatus {
        if !p.enabled { return .disabled }
        if p.kind == .foundation {
            if case .unavailable(let why) = onDevice { return .unavailable(why) }
            return .ready
        }
        if !p.needsKey { return .ready }
        return hasKey ? .ready : .missingKey(p.apiKeyEnv)
    }

    public var label: String {
        switch self {
        case .ready: "ready"
        case .disabled: "disabled"
        case .missingKey(let name): "missing key (\(name))"
        case .unavailable(let why): "unavailable: \(why)"
        }
    }
}

public struct DelegateError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

/// Logika czterech narzędzi MCP; zwraca gotowy tekst dla Claude'a.
public struct DelegateService: Sendable {
    let loadConfig: @Sendable () throws -> Config
    let saveConfig: (@Sendable (Config) throws -> Void)?
    let secrets: any SecretStore
    let transport: any HTTPTransport
    let usage: UsageLog
    let onDevice: any OnDeviceModel
    let priceCatalog: PriceCatalogStore?

    public init(
        loadConfig: @escaping @Sendable () throws -> Config,
        secrets: any SecretStore,
        transport: any HTTPTransport = URLSessionTransport(),
        onDevice: any OnDeviceModel = FoundationOnDeviceModel(),
        saveConfig: (@Sendable (Config) throws -> Void)? = nil,
        usage: UsageLog,
        priceCatalog: PriceCatalogStore? = nil
    ) {
        self.loadConfig = loadConfig
        self.saveConfig = saveConfig
        self.secrets = secrets
        self.transport = transport
        self.onDevice = onDevice
        self.usage = usage
        self.priceCatalog = priceCatalog
    }

    /// Standardowe podpięcie: katalog domowy, `.env` + Keychain.
    public init(home: DelegateHome, transport: any HTTPTransport = URLSessionTransport(),
                onDevice: any OnDeviceModel = FoundationOnDeviceModel()) {
        self.init(
            loadConfig: { try home.loadConfig() },
            secrets: CompositeSecretStore([EnvSecretStore(dotEnv: home.envURL), KeychainSecretStore()]),
            transport: transport,
            onDevice: onDevice,
            saveConfig: { try home.save($0) },
            usage: UsageLog(url: home.usageURL),
            priceCatalog: PriceCatalogStore(cacheURL: home.priceCatalogURL, transport: transport)
        )
    }

    /// Wylicza adaptacyjny timeout: uwzględnia bazowy timeout dostawcy/configu, długość promptu oraz limit tokenów.
    public static func computeTimeout(for request: DelegateRequest, provider: ProviderConfig, config: Config) -> TimeInterval {
        let base = provider.timeoutSeconds ?? config.timeoutSeconds
        let charCount = request.prompt.count + (request.system?.count ?? 0)
        // Każde 1000 znaków promptu powyżej 2000 znaków dodaje 1.5s na processing/prefill
        let promptAllowance = Double(max(0, charCount - 2000)) / 1000.0 * 1.5
        // Każdy oczekiwany token wyjściowy (maxTokens) dodaje 0.04s (odpowiednik ~25 tok/s generowania)
        let tokenAllowance = request.maxTokens.map { Double($0) * 0.04 } ?? 0
        let total = base + promptAllowance + tokenAllowance
        // Ograniczenie: dolna granica to bazowy timeout, górna to max 600 sekund (10 minut)
        return min(max(base, total), 600)
    }

    /// Aktualny config (czytany z dysku przy każdym wywołaniu).
    public func currentConfig() throws -> Config { try loadConfig() }

    /// Czy dostawca jest dziś używalny i dlaczego nie (do GUI i `list_models`).
    public func status(of p: ProviderConfig) -> ProviderStatus {
        ProviderStatus.evaluate(p, hasKey: p.needsKey && secrets.hasSecret(for: p.apiKeyEnv), onDevice: onDevice.availability)
    }

    /// Lekki test połączenia: lista modeli (chmura) albo dostępność (lokalnie).
    public func test(_ p: ProviderConfig) async -> Result<String, DelegateError> {
        if p.kind == .foundation {
            switch onDevice.availability {
            case .available: return .success("On-device model available")
            case .unavailable(let why): return .failure(DelegateError(description: why))
            }
        }
        let key = secrets.secret(for: p.apiKeyEnv) ?? ""
        if p.needsKey && key.isEmpty {
            return .failure(DelegateError(description: "Missing key \(p.apiKeyEnv)"))
        }
        do {
            let client = ProviderClient(transport: transport, timeout: 20)
            let ids = try await client.listModels(provider: p, apiKey: key)
            return .success("OK, \(ids.count) models")
        } catch {
            return .failure(DelegateError(description: "\(error)"))
        }
    }

    // MARK: list_models

    public func listModels() throws -> String {
        let config = try loadConfig()
        var out = "# Providers and models (by priority)\n\n"
        for (i, p) in config.providers.enumerated() {
            let status = self.status(of: p).label
            out += "\(i + 1). **\(p.id)** (\(p.kind.rawValue)) — \(status)\n"
            if let n = p.note { out += "   note: \(n)\n" }
            if let g = p.guidance, !g.isEmpty { out += "   guidance for Claude: \(g)\n" }
            for m in p.models {
                var line = "   - `\(p.id)/\(m.id)`"
                if !m.tags.isEmpty { line += " tags: \(m.tags.joined(separator: ", "))" }
                if let c = m.costLabel { line += " · cost: \(c)" }
                if let n = m.note { line += " · \(n)" }
                out += line + "\n"
            }
        }
        let guidance = config.routingGuidance.trimmingCharacters(in: .whitespacesAndNewlines)
        if !guidance.isEmpty { out += "\n## Routing rules\n\(guidance)\n" }
        return out
    }

    // MARK: delegate

    public func candidates(for request: DelegateRequest, config: Config) -> [Candidate] {
        routingPlan(for: request, config: config).candidates
    }

    /// Kolejność prób i powody pominięcia: status klucza, region danych vs `sensitivity`, dzienny budżet,
    /// potem tag i wskazany model. Wspólne dla `delegate` i podglądu w GUI.
    public func routingPlan(for request: DelegateRequest, config: Config, now: Date = Date()) -> RoutingPlan {
        var excluded: [RoutingExclusion] = []
        var usable: [ProviderConfig] = []
        for p in config.providers {
            let st = status(of: p)
            guard st == .ready else {
                excluded.append(RoutingExclusion(ref: p.id, reason: st.label))
                continue
            }
            let region = p.effectivePrivacy
            switch request.sensitivity {
            case .private where region != .local:
                excluded.append(RoutingExclusion(ref: p.id, reason: "private task stays on the Mac (region: \(region.rawValue))"))
                continue
            case .personal where !config.personalRegions.contains(region):
                excluded.append(RoutingExclusion(ref: p.id, reason: "personal data doesn't go to region \(region.rawValue)"))
                continue
            default:
                usable.append(p)
            }
        }
        var all = usable.flatMap { p in p.models.map { Candidate(provider: p, model: $0) } }

        var spent: Double?
        if let budget = config.dailyBudgetUSD {
            let today = Calendar.current.startOfDay(for: now)
            let s = usage.entries(since: today).compactMap(\.costUSD).reduce(0, +)
            spent = s
            if s >= budget {
                let reason = String(format: "daily budget used up ($%.2f of $%.2f)", s, budget)
                excluded += all.filter { !$0.model.isFree(at: $0.provider) }.map { RoutingExclusion(ref: $0.ref, reason: reason) }
                all = all.filter { $0.model.isFree(at: $0.provider) }
            }
        }

        if let task = request.task?.lowercased(), !task.isEmpty {
            let tagged = all.filter { $0.model.tags.contains { $0.lowercased() == task } }
            if !tagged.isEmpty { all = tagged + all.filter { c in !tagged.contains(c) } }
        }
        if let wanted = request.model, !wanted.isEmpty {
            let exact = all.filter { $0.ref == wanted || (!wanted.contains("/") && $0.model.id == wanted) }
            if request.allowFallback {
                // Fallback po modelu wybranym przez Claude'a: najpierw podobne (wspólne tagi), potem reszta wg priorytetu.
                let chosen = Set(exact.first?.model.tags.map { $0.lowercased() } ?? [])
                let shared = { (c: Candidate) in c.model.tags.filter { chosen.contains($0.lowercased()) }.count }
                let rest = all.filter { c in !exact.contains(c) }.enumerated()
                    .sorted { a, b in shared(a.element) != shared(b.element) ? shared(a.element) > shared(b.element) : a.offset < b.offset }
                    .map(\.element)
                all = exact + rest
            } else {
                all = exact
            }
        }
        return RoutingPlan(candidates: all, excluded: excluded, spentToday: spent)
    }

    struct Prepared {
        var request: DelegateRequest
        var config: Config
        var plan: RoutingPlan
        var attached: FileAttachments.Composed
        var output: URL?
    }

    /// Wszystko, co może odrzucić zadanie przed wywołaniem modelu (pliki, routing, sekrety).
    /// Zadania w tle wołają to od razu, żeby błąd wrócił do Claude'a, a nie dopiero w wyniku.
    public func preflight(_ request: DelegateRequest) throws {
        _ = try prepare(request)
    }

    func prepare(_ original: DelegateRequest) throws -> Prepared {
        let config = try loadConfig()
        // Pliki doklejamy przed wszystkim innym: limity czasu i wykrywanie sekretów dotyczą pełnej treści.
        let attached = try FileAttachments.compose(prompt: original.prompt, paths: original.files)
        let output = try original.outputFile.map(OutputFile.validate)
        var request = original
        request.prompt = attached.prompt
        let plan = routingPlan(for: request, config: config)
        let list = plan.candidates
        guard !list.isEmpty else {
            let why = plan.excluded.prefix(10).map { "- \($0.ref): \($0.reason)" }.joined(separator: "\n")
            let detail = why.isEmpty ? "" : "\nSkipped:\n" + why
            if let m = request.model {
                throw DelegateError(description: "Model \"\(m)\" unavailable for this task.\(detail)")
            }
            throw DelegateError(description: "No models for this task (sensitivity: \(request.sensitivity.rawValue)).\(detail)")
        }

        // Weryfikacja pod kątem wycieku sekretów do dostawców zewnętrznych
        if !request.allowSecrets {
            let targetsCloud = list.contains { $0.provider.effectivePrivacy != .local }
            if targetsCloud, let leak = SecretLeakDetector.scan(request.prompt) ?? (request.system.flatMap(SecretLeakDetector.scan)) {
                throw DelegateError(
                    description: "Possible secret detected in the prompt (\(leak.type): \(leak.matched)). If you are intentionally sending this data to an external model, set allow_secrets = true."
                )
            }
        }

        return Prepared(request: request, config: config, plan: plan, attached: attached, output: output)
    }

    public func delegate(_ original: DelegateRequest) async throws -> String {
        let p = try prepare(original)
        let (request, config, plan, attached, output) = (p.request, p.config, p.plan, p.attached, p.output)
        let list = plan.candidates

        let chat = ChatRequest(prompt: request.prompt, system: request.system,
                               temperature: request.temperature, maxTokens: request.maxTokens,
                               jsonMode: request.jsonMode)
        var failures: [String] = []

        for c in list {
            let timeout = Self.computeTimeout(for: request, provider: c.provider, config: config)
            let client = ProviderClient(transport: transport, timeout: timeout)
            let key = secrets.secret(for: c.provider.apiKeyEnv) ?? ""
            let started = Date()
            do {
                let reply: ChatReply
                if c.provider.kind == .foundation {
                    reply = try await onDevice.respond(chat)
                } else {
                    reply = try await client.chat(provider: c.provider, model: c.model.id, apiKey: key, request: chat)
                }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let cost = CostCalculator.computeCost(model: c.model, inputTokens: reply.inputTokens, outputTokens: reply.outputTokens)
                usage.append(UsageEntry(provider: c.provider.id, model: c.model.id, task: request.task,
                                        inputTokens: reply.inputTokens, outputTokens: reply.outputTokens,
                                        costUSD: cost,
                                        ok: true, ms: ms))
                var h = header(c, reply, ms: ms, cost: cost, failures: failures)
                if attached.count > 0 { h += " · files: \(attached.count) (\(max(1, attached.bytes / 1024)) KB)" }
                if let spent = plan.spentToday, let budget = config.dailyBudgetUSD {
                    h += String(format: " · budget today: $%.2f/$%.2f", spent + (cost ?? 0), budget)
                }
                if let output {
                    do {
                        return h + "\n\n" + (try OutputFile.write(reply.text, to: output))
                    } catch {
                        // Odpowiedź już zapłacona: oddajemy ją, zamiast gubić.
                        return h + "\n\nCouldn't write \(output.path) (\(error)); reply follows.\n\n" + reply.text
                    }
                }
                return h + "\n\n" + reply.text
            } catch {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                usage.append(UsageEntry(provider: c.provider.id, model: c.model.id, task: request.task,
                                        ok: false, error: String(describing: error), ms: ms))
                failures.append("\(c.ref) → \(error)")
                if !request.allowFallback { break }
            }
        }
        throw DelegateError(description: "All attempts failed:\n" + failures.map { "- \($0)" }.joined(separator: "\n"))
    }

    private func header(_ c: Candidate, _ r: ChatReply, ms: Int, cost: Double?, failures: [String]) -> String {
        let tokens = "\(r.inputTokens.map(String.init) ?? "?") in / \(r.outputTokens.map(String.init) ?? "?") out"
        var h = "[delegate] model: \(c.ref) · tokens: \(tokens)"
        if let cost {
            h += String(format: " · cost: $%.4f", cost)
        }
        h += " · \(String(format: "%.1f", Double(ms) / 1000)) s"
        h += failures.isEmpty ? " · fallbacks: none" : " · fallbacks: " + failures.joined(separator: "; ")
        return h
    }

    // MARK: list_remote_models

    /// ID modeli z API dostawcy (do GUI); dla modelu lokalnego `["on-device"]`.
    public func remoteModelIDs(for p: ProviderConfig) async throws -> [String] {
        try await modelInfos(for: p).map(\.id)
    }

    /// Modele z metadanymi i sugestiami tagów (do GUI i `list_remote_models`). Ceny, których API
    /// nie podaje, uzupełnia z cennika LiteLLM (jeśli zna tego dostawcę).
    public func modelInfos(for p: ProviderConfig) async throws -> [ModelInfo] {
        if p.kind == .foundation { return [ModelInfo(id: "on-device", contextLength: 4096, priceIn: 0, priceOut: 0)] }
        let key = secrets.secret(for: p.apiKeyEnv) ?? ""
        if p.needsKey && key.isEmpty { throw ProviderError.missingKey(p.apiKeyEnv) }
        let timeout = p.timeoutSeconds ?? 30
        var infos = try await ProviderClient(transport: transport, timeout: timeout).listModelInfo(provider: p, apiKey: key)
        guard PriceCatalog.catalogProvider(forBaseURL: p.baseURL) != nil, let store = priceCatalog else { return infos }
        func unpriced() -> [Int] { infos.indices.filter { infos[$0].priceIn == nil && infos[$0].priceOut == nil } }
        func fill(from catalog: PriceCatalog) {
            for i in unpriced() {
                guard let price = catalog.price(for: infos[i].id, provider: p) else { continue }
                infos[i].priceIn = price.input
                infos[i].priceOut = price.output
                infos[i].priceSource = PriceCatalog.sourceName
            }
        }
        guard !unpriced().isEmpty, let catalog = await store.load() else { return infos }
        fill(from: catalog)
        // Nowy model, którego nie ma w kopii: spróbuj świeżego cennika (najwyżej raz na dobę).
        let chatMissing = unpriced().contains { infos[$0].isChat }
        if chatMissing, store.canRefreshOnMiss, let fresh = await store.load(forceRefresh: true) {
            fill(from: fresh)
        }
        return infos
    }

    /// Pobiera cennik od nowa (przycisk w GUI). Zwraca datę kopii, `nil` przy braku sieci i kopii.
    @discardableResult
    public func refreshPriceCatalog() async -> Date? {
        guard let store = priceCatalog, await store.load(forceRefresh: true) != nil else { return nil }
        return store.cacheDate
    }

    /// Data lokalnej kopii cennika LiteLLM.
    public var priceCatalogDate: Date? { priceCatalog?.cacheDate }

    public func listRemoteModels(providerID: String?) async throws -> String {
        let config = try loadConfig()
        let targets = config.providers.filter { providerID == nil || $0.id == providerID }
        guard !targets.isEmpty else { throw DelegateError(description: "No provider named \"\(providerID ?? "")\".") }

        var out = ""
        for p in targets {
            if p.kind == .foundation {
                out += "## \(p.id)\n- on-device (\(status(of: p).label))\n\n"
                continue
            }
            if p.needsKey && !secrets.hasSecret(for: p.apiKeyEnv) {
                out += "## \(p.id)\nmissing key (\(p.apiKeyEnv))\n\n"
                continue
            }
            do {
                let infos = try await modelInfos(for: p)
                let lines = infos.map { i -> String in
                    var line = "- \(i.id)"
                    let tags = i.suggestedTags
                    if !tags.isEmpty { line += " — suggested tags: \(tags.joined(separator: ", "))" }
                    if !i.summary.isEmpty { line += " (\(i.summary))" }
                    return line
                }
                out += "## \(p.id) (\(infos.count))\n" + lines.joined(separator: "\n") + "\n\n"
            } catch {
                out += "## \(p.id)\nerror: \(error)\n\n"
            }
        }
        return out
    }

    // MARK: update_models

    /// Upsert modeli (tagi, koszt) w configu; klucze API i reszta pliku nietknięte.
    public func updateModels(provider providerID: String, updates: [ModelUpdate]) throws -> String {
        guard let saveConfig else { throw DelegateError(description: "Saving the config is unavailable in this mode.") }
        var config = try loadConfig()
        guard let pi = config.providers.firstIndex(where: { $0.id == providerID }) else {
            throw DelegateError(description: "No provider named \"\(providerID)\". Use list_models.")
        }
        var changed = 0, added = 0
        for u in updates {
            let id = u.id.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { continue }
            if let mi = config.providers[pi].models.firstIndex(where: { $0.id == id }) {
                u.apply(to: &config.providers[pi].models[mi])
                changed += 1
            } else {
                var m = ModelConfig(id: id)
                u.apply(to: &m)
                config.providers[pi].models.append(m)
                added += 1
            }
        }
        try saveConfig(config)
        return "Saved delegate.toml: updated \(changed), added \(added) (provider \(providerID))."
    }

    // MARK: usage_summary

    public func usageSummary(days: Int = 7, now: Date = Date()) -> String {
        let since = Calendar.current.date(byAdding: .day, value: -max(days, 1), to: now)
        let entries = usage.entries(since: since)
        guard !entries.isEmpty else { return "No calls in the last \(days) days." }

        struct Agg { var calls = 0, failed = 0, input = 0, output = 0, cost: Double = 0.0 }
        var byModel: [String: Agg] = [:]
        for e in entries {
            var a = byModel["\(e.provider)/\(e.model)", default: Agg()]
            a.calls += 1
            if !e.ok { a.failed += 1 }
            a.input += e.inputTokens ?? 0
            a.output += e.outputTokens ?? 0
            a.cost += e.costUSD ?? 0.0
            byModel["\(e.provider)/\(e.model)"] = a
        }
        var out = "# Usage for the last \(days) days\n\n"
        for (ref, a) in byModel.sorted(by: { $0.value.calls > $1.value.calls }) {
            var line = "- `\(ref)`: \(a.calls) calls (errors: \(a.failed)), tokens: \(a.input) in / \(a.output) out"
            if a.cost > 0 {
                line += String(format: " · $%.4f", a.cost)
            }
            out += line + "\n"
        }
        let totalCost = entries.compactMap(\.costUSD).reduce(0, +)
        let totalInput = entries.compactMap(\.inputTokens).reduce(0, +)
        let totalOutput = entries.compactMap(\.outputTokens).reduce(0, +)
        let saved = CostCalculator.savingsVsSonnet(entries)
        let unpriced = entries.filter { $0.ok && $0.costUSD == nil }.count

        out += "\nTotal: \(entries.count) calls, \(totalInput) in / \(totalOutput) out"
        out += String(format: "\nTotal cost: $%.4f · Saved vs Sonnet: $%.4f", totalCost, saved)
        if unpriced > 0 { out += "\n(\(unpriced) calls without a known model price, skipped in costs)" }
        return out
    }
}
