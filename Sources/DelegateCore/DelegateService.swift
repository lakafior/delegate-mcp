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

    public init(prompt: String, system: String? = nil, model: String? = nil, task: String? = nil,
                temperature: Double? = nil, maxTokens: Int? = nil, allowFallback: Bool = true) {
        self.prompt = prompt
        self.system = system
        self.model = model
        self.task = task
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.allowFallback = allowFallback
    }
}

public struct Candidate: Sendable, Equatable {
    public var provider: ProviderConfig
    public var model: ModelConfig
    public var ref: String { "\(provider.id)/\(model.id)" }
}

public struct DelegateError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

/// Logika czterech narzędzi MCP; zwraca gotowy tekst dla Claude'a.
public struct DelegateService: Sendable {
    let loadConfig: @Sendable () throws -> Config
    let secrets: any SecretStore
    let transport: any HTTPTransport
    let usage: UsageLog

    public init(
        loadConfig: @escaping @Sendable () throws -> Config,
        secrets: any SecretStore,
        transport: any HTTPTransport = URLSessionTransport(),
        usage: UsageLog
    ) {
        self.loadConfig = loadConfig
        self.secrets = secrets
        self.transport = transport
        self.usage = usage
    }

    /// Standardowe podpięcie: katalog domowy, `.env` + Keychain.
    public init(home: DelegateHome, transport: any HTTPTransport = URLSessionTransport()) {
        self.init(
            loadConfig: { try home.loadConfig() },
            secrets: CompositeSecretStore([EnvSecretStore(dotEnv: home.envURL), KeychainSecretStore()]),
            transport: transport,
            usage: UsageLog(url: home.usageURL)
        )
    }

    // MARK: list_models

    public func listModels() throws -> String {
        let config = try loadConfig()
        var out = "# Dostawcy i modele (wg priorytetu)\n\n"
        for (i, p) in config.providers.enumerated() {
            let status: String
            if !p.enabled { status = "wyłączony" }
            else if secrets.secret(for: p.apiKeyEnv) == nil { status = "brak klucza (\(p.apiKeyEnv))" }
            else { status = "klucz OK" }
            out += "\(i + 1). **\(p.id)** (\(p.kind.rawValue)) — \(status)\n"
            if let n = p.note { out += "   uwaga: \(n)\n" }
            for m in p.models {
                var line = "   - `\(p.id)/\(m.id)`"
                if !m.tags.isEmpty { line += " tagi: \(m.tags.joined(separator: ", "))" }
                if let c = m.cost { line += " · koszt: \(c)" }
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
        let usable = config.providers.filter { $0.enabled && secrets.secret(for: $0.apiKeyEnv) != nil }
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

        let client = ProviderClient(transport: transport, timeout: config.timeoutSeconds)
        let chat = ChatRequest(prompt: request.prompt, system: request.system,
                               temperature: request.temperature, maxTokens: request.maxTokens)
        var failures: [String] = []

        for c in list {
            let key = secrets.secret(for: c.provider.apiKeyEnv) ?? ""
            let started = Date()
            do {
                let reply = try await client.chat(provider: c.provider, model: c.model.id, apiKey: key, request: chat)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                usage.append(UsageEntry(provider: c.provider.id, model: c.model.id, task: request.task,
                                        inputTokens: reply.inputTokens, outputTokens: reply.outputTokens,
                                        ok: true, ms: ms))
                return header(c, reply, ms: ms, failures: failures) + "\n\n" + reply.text
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

    private func header(_ c: Candidate, _ r: ChatReply, ms: Int, failures: [String]) -> String {
        let tokens = "\(r.inputTokens.map(String.init) ?? "?") in / \(r.outputTokens.map(String.init) ?? "?") out"
        var h = "[delegate] model: \(c.ref) · tokeny: \(tokens) · \(String(format: "%.1f", Double(ms) / 1000)) s"
        h += failures.isEmpty ? " · fallbacki: brak" : " · fallbacki: " + failures.joined(separator: "; ")
        return h
    }

    // MARK: list_remote_models

    public func listRemoteModels(providerID: String?) async throws -> String {
        let config = try loadConfig()
        let targets = config.providers.filter { providerID == nil || $0.id == providerID }
        guard !targets.isEmpty else { throw DelegateError(description: "Nie ma dostawcy „\(providerID ?? "")”.") }

        let client = ProviderClient(transport: transport, timeout: config.timeoutSeconds)
        var out = ""
        for p in targets {
            guard let key = secrets.secret(for: p.apiKeyEnv) else {
                out += "## \(p.id)\nbrak klucza (\(p.apiKeyEnv))\n\n"
                continue
            }
            do {
                let ids = try await client.listModels(provider: p, apiKey: key)
                out += "## \(p.id) (\(ids.count))\n" + ids.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            } catch {
                out += "## \(p.id)\nbłąd: \(error)\n\n"
            }
        }
        return out
    }

    // MARK: usage_summary

    public func usageSummary(days: Int = 7, now: Date = Date()) -> String {
        let since = Calendar.current.date(byAdding: .day, value: -max(days, 1), to: now)
        let entries = usage.entries(since: since)
        guard !entries.isEmpty else { return "Brak wywołań w ostatnich \(days) dniach." }

        struct Agg { var calls = 0, failed = 0, input = 0, output = 0 }
        var byModel: [String: Agg] = [:]
        for e in entries {
            var a = byModel["\(e.provider)/\(e.model)", default: Agg()]
            a.calls += 1
            if !e.ok { a.failed += 1 }
            a.input += e.inputTokens ?? 0
            a.output += e.outputTokens ?? 0
            byModel["\(e.provider)/\(e.model)"] = a
        }
        var out = "# Użycie z ostatnich \(days) dni\n\n"
        for (ref, a) in byModel.sorted(by: { $0.value.calls > $1.value.calls }) {
            out += "- `\(ref)`: \(a.calls) wywołań (błędy: \(a.failed)), tokeny: \(a.input) in / \(a.output) out\n"
        }
        out += "\nRazem: \(entries.count) wywołań, \(entries.compactMap(\.inputTokens).reduce(0, +)) in / \(entries.compactMap(\.outputTokens).reduce(0, +)) out"
        return out
    }
}
