import Foundation

/// Teksty, którymi serwer MCP mówi Claude'owi, kiedy i jak delegować: instrukcje serwera
/// (Claude Code i Desktop wstrzykują je do każdego zapytania) oraz opisy narzędzi.
/// Idą w każdej turze, więc mają być krótkie: katalog to jedna linia na dostawcę, pełna lista w `list_models`.
/// Model wybiera Claude; serwer pilnuje tylko twardych granic (regiony, budżet, sekrety).
/// Po angielsku, niezależnie od języka GUI.
public struct DelegationGuide: Sendable {
    /// Gotowe do użycia (włączone, z kluczem) modele wg priorytetu.
    public let candidates: [Candidate]
    public let routingGuidance: String
    /// Wskazówki użytkownika per dostawca (tylko gotowi), w kolejności priorytetu.
    public let providerGuidance: [(id: String, text: String)]
    public let mode: DelegationMode
    public let personalRegions: [PrivacyRegion]
    public let dailyBudgetUSD: Double?

    /// Ile modeli dostawcy pokazać w katalogu; resztę Claude znajdzie w `list_models`.
    static let modelsPerProvider = 5

    /// Zainstalowani agenci ACP (`delegate_agent`); pusta lista = bez wzmianki w instrukcjach.
    public let agents: [String]
    /// Domyślne opcje agentów z configu, pokazywane przy nazwie (np. `claude-acp: haiku, low`).
    let agentSettings: [AgentSettings]

    var agentList: String {
        agents.map { id in
            guard let s = agentSettings.first(where: { $0.id == id }) else { return id }
            let parts = [s.model, s.effort].compactMap { $0 }
            return parts.isEmpty ? id : "\(id): \(parts.joined(separator: ", "))"
        }.joined(separator: "; ")
    }

    public init(config: Config, agents: [String] = [], isReady: (ProviderConfig) -> Bool) {
        self.agents = agents
        self.agentSettings = config.agents
        let ready = config.providers.filter(isReady)
        mode = config.delegationMode
        personalRegions = config.personalRegions
        dailyBudgetUSD = config.dailyBudgetUSD
        candidates = ready.flatMap { p in p.models.map { Candidate(provider: p, model: $0) } }
        routingGuidance = config.routingGuidance.trimmingCharacters(in: .whitespacesAndNewlines)
        providerGuidance = ready.compactMap { p in
            let text = (p.guidance ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (p.id, text.replacingOccurrences(of: "\n", with: " "))
        }
    }

    /// Tagi, których nie pokazujemy: `delegate` wysyła tylko tekst („vision” by mylił), a `translate`
    /// i `summarize` wynikają z `general`.
    static let hiddenTags: Set<String> = ["vision"]
    static let impliedByGeneral: Set<String> = ["translate", "summarize"]

    /// Tagi w kolejności pierwszego wystąpienia (czyli wg priorytetu dostawców).
    public var tags: [String] {
        var seen = Set<String>(Self.hiddenTags)
        return candidates.flatMap { $0.model.tags.map { $0.lowercased() } }.filter { seen.insert($0).inserted }
    }

    // MARK: katalog

    private func cost(_ m: ModelConfig) -> String {
        if m.priceIn != nil || m.priceOut != nil { return "$\(ModelConfig.money(m.priceIn))/$\(ModelConfig.money(m.priceOut))" }
        return m.cost ?? "?"
    }

    private func shownTags(_ m: ModelConfig) -> [String] {
        let tags = m.tags.map { $0.lowercased() }.filter { !Self.hiddenTags.contains($0) }
        return tags.contains("general") ? tags.filter { !Self.impliedByGeneral.contains($0) } : tags
    }

    /// `- mistral · eu · free: mistral-small-latest (general, fast), codestral-latest (code) +3. Note: …`
    var catalog: String {
        var providers: [ProviderConfig] = []
        for c in candidates where !providers.contains(where: { $0.id == c.provider.id }) { providers.append(c.provider) }
        let notes = Dictionary(providerGuidance.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        return providers.map { p in
            let costs = Set(p.models.map(cost))
            let shared = costs.count == 1 ? costs.first : nil
            let models = p.models.prefix(Self.modelsPerProvider).map { m -> String in
                var parts: [String] = []
                if shared == nil { parts.append(cost(m)) }
                parts += shownTags(m)
                return parts.isEmpty ? m.id : "\(m.id) (\(parts.joined(separator: ", ")))"
            }
            var line = "- \(p.id) · \(p.effectivePrivacy.rawValue)"
            if let shared { line += " · \(shared)" }
            line += ": " + models.joined(separator: ", ")
            if p.models.count > Self.modelsPerProvider { line += " +\(p.models.count - Self.modelsPerProvider)" }
            if let note = notes[p.id] { line += ". Note: \(note)" }
            return line
        }.joined(separator: "\n")
    }

    // MARK: instrukcje serwera

    public var serverInstructions: String {
        guard !candidates.isEmpty else {
            return "The `delegate` server has no usable models (no enabled provider with a key). Don't call `delegate`."
        }
        var out = """
        `delegate` hands work to cheaper models to save the usage limits of the assistant you are running on. \(modeIntro) \
        The model has no tools and sees only `prompt` and `files`, but the server does the file I/O:
        - `files`: absolute paths the server reads. Don't read or retype big files just to pass them on.
        - `output_file`: the server writes the reply there and you get a preview. Use it whenever the result \
        is a file; then check it with `git diff`.
        - `background: true`: returns a job ID at once. Start several independent jobs in one turn, keep \
        working, collect them with `delegate_result`. Use it for anything that may take over ~40 s (whole files, \
        long output): sync calls are cut off at \(Int(DelegateRequest.syncDeadlineSeconds)) s.

        Good fits: translating or extending locale files; docs, README, changelog, commit message drafts; test \
        data and fixtures; boilerplate modelled on an example file; mechanical rewrites of one file; summaries \
        or first-pass reviews of long files and logs (ask for a short report, so you read less); any text over \
        ~\(wordThreshold) words that doesn't depend on things only you can see. You are the conductor: pick the \
        files, write a precise brief (task, constraints, exact output format, e.g. "only the file content"), \
        review what comes back. Do it yourself: edits spanning many files, design, debugging that needs running \
        code, short answers.

        Choose `model` from the catalog below by what the task needs, cost (prefer free at similar quality), and \
        data region. Without `model`, the server routes by `task` tag and provider order, falling back on errors.
        """
        out += "\n\n" + sensitivitySection
        if let budget = dailyBudgetUSD {
            out += String(format: "\nPaid models stop for the day after $%.2f; the server enforces it.", budget)
        }
        out += "\n\nCatalog (provider · data region · cost per 1M in/out): \n" + catalog
        if !agents.isEmpty {
            out += "\n\n`delegate_agent` runs a coding agent (\(agentList)) on a git repo in the background, in a sandbox. "
                + "Read mode: repo-wide searches and analysis (where X is used, what must change, a module review) instead of "
                + "reading many files yourself; spot-check its file:line claims. Write mode: well-scoped changes (translations, "
                + "tests, refactors, a feature slice) on a branch `delegate/…`; review its diff before merging. "
                + "Independent jobs can run in parallel; results via `delegate_result`."
        }
        if !routingGuidance.isEmpty { out += "\n\nUser's rules: " + routingGuidance }
        return out
    }

    private var modeIntro: String {
        switch mode {
        case .conservative: "Delegate only clearly worthwhile tasks; when in doubt, do it yourself."
        case .balanced: "Use it proactively."
        case .aggressive: "Delegate by default whenever the task fits."
        }
    }

    private var wordThreshold: Int {
        switch mode {
        case .conservative: 400
        case .balanced: 150
        case .aggressive: 50
        }
    }

    /// Opis `sensitivity` z faktycznymi regionami i dostawcami lokalnymi; serwer to egzekwuje.
    var sensitivitySection: String {
        let local = Array(Set(candidates.filter { $0.provider.effectivePrivacy == .local }.map(\.provider.id))).sorted()
        let regions = personalRegions.map(\.rawValue).joined(separator: ", ")
        let priv = local.isEmpty ? "no local model is ready, do it yourself" : "local models only (\(local.joined(separator: ", ")))"
        return "`sensitivity` (enforced): `public` default; `personal` = personal or work data, regions \(regions); "
            + "`private` = stays on this Mac, \(priv). Never send secrets."
    }

    // MARK: opisy narzędzi

    public var toolDescription: String {
        candidates.isEmpty
            ? "Send a task to a cheaper model. No models are available right now."
            : "Send a task to a cheaper model (saves your usage limits); files in via `files`, out via `output_file`, parallel via `background`. See the server instructions for when and which model."
    }

    public var modelParameterDescription: String {
        "provider/model from the catalog in the server instructions (full list: list_models). Empty = route by `task`."
    }
}

extension DelegateService {
    public func guide(config: Config, agents: [String] = []) -> DelegationGuide {
        DelegationGuide(config: config, agents: agents) { status(of: $0) == .ready }
    }
}
