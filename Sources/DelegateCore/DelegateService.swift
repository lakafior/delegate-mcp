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

    public init(prompt: String, system: String? = nil, model: String? = nil, task: String? = nil,
                temperature: Double? = nil, maxTokens: Int? = nil, allowFallback: Bool = true,
                allowSecrets: Bool = false, jsonMode: Bool = false) {
        self.prompt = prompt
        self.system = system
        self.model = model
        self.task = task
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.allowFallback = allowFallback
        self.allowSecrets = allowSecrets
        self.jsonMode = jsonMode
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
        case .ready: "gotowy"
        case .disabled: "wyłączony"
        case .missingKey(let name): "brak klucza (\(name))"
        case .unavailable(let why): "niedostępny: \(why)"
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

    public init(
        loadConfig: @escaping @Sendable () throws -> Config,
        secrets: any SecretStore,
        transport: any HTTPTransport = URLSessionTransport(),
        onDevice: any OnDeviceModel = FoundationOnDeviceModel(),
        saveConfig: (@Sendable (Config) throws -> Void)? = nil,
        usage: UsageLog
    ) {
        self.loadConfig = loadConfig
        self.saveConfig = saveConfig
        self.secrets = secrets
        self.transport = transport
        self.onDevice = onDevice
        self.usage = usage
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
            usage: UsageLog(url: home.usageURL)
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
            case .available: return .success("Model na urządzeniu dostępny")
            case .unavailable(let why): return .failure(DelegateError(description: why))
            }
        }
        let key = secrets.secret(for: p.apiKeyEnv) ?? ""
        if p.needsKey && key.isEmpty {
            return .failure(DelegateError(description: "Brak klucza \(p.apiKeyEnv)"))
        }
        do {
            let client = ProviderClient(transport: transport, timeout: 20)
            let ids = try await client.listModels(provider: p, apiKey: key)
            return .success("OK, \(ids.count) modeli")
        } catch {
            return .failure(DelegateError(description: "\(error)"))
        }
    }

    // MARK: list_models

    public func listModels() throws -> String {
        let config = try loadConfig()
        var out = "# Dostawcy i modele (wg priorytetu)\n\n"
        for (i, p) in config.providers.enumerated() {
            let status = self.status(of: p).label
            out += "\(i + 1). **\(p.id)** (\(p.kind.rawValue)) — \(status)\n"
            if let n = p.note { out += "   uwaga: \(n)\n" }
            for m in p.models {
                var line = "   - `\(p.id)/\(m.id)`"
                if !m.tags.isEmpty { line += " tagi: \(m.tags.joined(separator: ", "))" }
                if let c = m.costLabel { line += " · koszt: \(c)" }
                if let n = m.note { line += " · \(n)" }
                out += line + "\n"
            }
        }
        let guidance = config.routingGuidance.trimmingCharacters(in: .whitespacesAndNewlines)
        if !guidance.isEmpty { out += "\n## Zasady routingu\n\(guidance)\n" }
        return out
    }

    // MARK: delegate

    public func candidates(for request: DelegateRequest, config: Config) -> [Candidate] {
        let usable = config.providers.filter { status(of: $0) == .ready }
        var all = usable.flatMap { p in p.models.map { Candidate(provider: p, model: $0) } }

        if let task = request.task?.lowercased(), !task.isEmpty {
            let tagged = all.filter { $0.model.tags.contains { $0.lowercased() == task } }
            if !tagged.isEmpty { all = tagged + all.filter { c in !tagged.contains(c) } }
        }
        if let wanted = request.model, !wanted.isEmpty {
            let exact = all.filter { $0.ref == wanted || (!wanted.contains("/") && $0.model.id == wanted) }
            all = request.allowFallback ? exact + all.filter { c in !exact.contains(c) } : exact
        }
        return all
    }

    public func delegate(_ request: DelegateRequest) async throws -> String {
        let config = try loadConfig()
        let list = candidates(for: request, config: config)
        guard !list.isEmpty else {
            if let m = request.model {
                throw DelegateError(description: "Model „\(m)” niedostępny (brak w configu, wyłączony albo bez klucza). Użyj list_models.")
            }
            throw DelegateError(description: "Brak dostępnych modeli. Sprawdź klucze i config przez list_models.")
        }

        // Weryfikacja pod kątem wycieku sekretów do dostawców zewnętrznych
        if !request.allowSecrets {
            let targetsCloud = list.contains { $0.provider.kind != .foundation }
            if targetsCloud, let leak = SecretLeakDetector.scan(request.prompt) ?? (request.system.flatMap(SecretLeakDetector.scan)) {
                throw DelegateError(
                    description: "Wykryto potencjalny sekret w prompcie (\(leak.type): \(leak.matched)). Jeśli celowo wysyłasz te dane do zewnętrznego modelu, ustaw allow_secrets = true."
                )
            }
        }

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
                return header(c, reply, ms: ms, cost: cost, failures: failures) + "\n\n" + reply.text
            } catch {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                usage.append(UsageEntry(provider: c.provider.id, model: c.model.id, task: request.task,
                                        ok: false, error: String(describing: error), ms: ms))
                failures.append("\(c.ref) → \(error)")
                if !request.allowFallback { break }
            }
        }
        throw DelegateError(description: "Wszystkie próby zawiodły:\n" + failures.map { "- \($0)" }.joined(separator: "\n"))
    }

    private func header(_ c: Candidate, _ r: ChatReply, ms: Int, cost: Double?, failures: [String]) -> String {
        let tokens = "\(r.inputTokens.map(String.init) ?? "?") in / \(r.outputTokens.map(String.init) ?? "?") out"
        var h = "[delegate] model: \(c.ref) · tokeny: \(tokens)"
        if let cost {
            h += String(format: " · koszt: $%.4f", cost)
        }
        h += " · \(String(format: "%.1f", Double(ms) / 1000)) s"
        h += failures.isEmpty ? " · fallbacki: brak" : " · fallbacki: " + failures.joined(separator: "; ")
        return h
    }

    // MARK: list_remote_models

    /// ID modeli z API dostawcy (do GUI); dla modelu lokalnego `["on-device"]`.
    public func remoteModelIDs(for p: ProviderConfig) async throws -> [String] {
        try await modelInfos(for: p).map(\.id)
    }

    /// Modele z metadanymi i sugestiami tagów (do GUI i `list_remote_models`).
    public func modelInfos(for p: ProviderConfig) async throws -> [ModelInfo] {
        if p.kind == .foundation { return [ModelInfo(id: "on-device", contextLength: 4096, priceIn: 0, priceOut: 0)] }
        let key = secrets.secret(for: p.apiKeyEnv) ?? ""
        if p.needsKey && key.isEmpty { throw ProviderError.missingKey(p.apiKeyEnv) }
        return try await ProviderClient(transport: transport, timeout: 30).listModelInfo(provider: p, apiKey: key)
    }

    public func listRemoteModels(providerID: String?) async throws -> String {
        let config = try loadConfig()
        let targets = config.providers.filter { providerID == nil || $0.id == providerID }
        guard !targets.isEmpty else { throw DelegateError(description: "Nie ma dostawcy „\(providerID ?? "")”.") }

        var out = ""
        for p in targets {
            if p.kind == .foundation {
                out += "## \(p.id)\n- on-device (\(status(of: p).label))\n\n"
                continue
            }
            let key = secrets.secret(for: p.apiKeyEnv) ?? ""
            if p.needsKey && key.isEmpty {
                out += "## \(p.id)\nbrak klucza (\(p.apiKeyEnv))\n\n"
                continue
            }
            do {
                let client = ProviderClient(transport: transport, timeout: p.timeoutSeconds ?? config.timeoutSeconds)
                let infos = try await client.listModelInfo(provider: p, apiKey: key)
                let lines = infos.map { i -> String in
                    var line = "- \(i.id)"
                    let tags = i.suggestedTags
                    if !tags.isEmpty { line += " — sugerowane tagi: \(tags.joined(separator: ", "))" }
                    if !i.summary.isEmpty { line += " (\(i.summary))" }
                    return line
                }
                out += "## \(p.id) (\(infos.count))\n" + lines.joined(separator: "\n") + "\n\n"
            } catch {
                out += "## \(p.id)\nbłąd: \(error)\n\n"
            }
        }
        return out
    }

    // MARK: update_models

    /// Upsert modeli (tagi, koszt) w configu; klucze API i reszta pliku nietknięte.
    public func updateModels(provider providerID: String, updates: [ModelUpdate]) throws -> String {
        guard let saveConfig else { throw DelegateError(description: "Zapis configu niedostępny w tym trybie.") }
        var config = try loadConfig()
        guard let pi = config.providers.firstIndex(where: { $0.id == providerID }) else {
            throw DelegateError(description: "Nie ma dostawcy „\(providerID)”. Użyj list_models.")
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
        return "Zapisano delegate.toml: zaktualizowano \(changed), dodano \(added) (dostawca \(providerID))."
    }

    // MARK: usage_summary

    public func usageSummary(days: Int = 7, now: Date = Date()) -> String {
        let since = Calendar.current.date(byAdding: .day, value: -max(days, 1), to: now)
        let entries = usage.entries(since: since)
        guard !entries.isEmpty else { return "Brak wywołań w ostatnich \(days) dniach." }

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
        var out = "# Użycie z ostatnich \(days) dni\n\n"
        for (ref, a) in byModel.sorted(by: { $0.value.calls > $1.value.calls }) {
            var line = "- `\(ref)`: \(a.calls) wywołań (błędy: \(a.failed)), tokeny: \(a.input) in / \(a.output) out"
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

        out += "\nRazem: \(entries.count) wywołań, \(totalInput) in / \(totalOutput) out"
        out += String(format: "\nKoszt całkowity: $%.4f · Zaoszczędzono vs Sonnet: $%.4f", totalCost, saved)
        if unpriced > 0 { out += "\n(\(unpriced) wywołań bez znanej ceny modelu, pominięte w kosztach)" }
        return out
    }
}
