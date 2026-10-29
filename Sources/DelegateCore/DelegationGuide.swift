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

    /// Claude Code ucina instrukcje serwera po ok. 4096 znakach (koniec zastąpiony „… [truncated]”; z dziewięcioma
    /// dostawcami przepadały zasady agentów). Składamy je do tego limitu z zapasem; skraca się tylko katalog.
    static let instructionsLimit = 3800

    /// Zainstalowani agenci ACP (`delegate_agent`) wg priorytetu; pusta lista = bez wzmianki w instrukcjach.
    public let agents: [String]
    /// Domyślne opcje i wskazówki agentów z configu, pokazywane przy nazwie (np. `claude-acp: haiku, low — …`).
    let agentSettings: [AgentSettings]

    var agentList: String {
        agents.map { id in
            guard let s = agentSettings.first(where: { $0.id == id }) else { return id }
            let parts = [s.model, s.effort].compactMap { $0 }
            var line = parts.isEmpty ? id : "\(id): \(parts.joined(separator: ", "))"
            if let g = s.guidance { line += " — \(g)" }
            return line
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
    private func catalogLine(_ p: ProviderConfig, models shown: [ModelConfig], note: Bool) -> String {
        let notes = Dictionary(providerGuidance.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        let costs = Set(p.models.map(cost))
        let shared = costs.count == 1 ? costs.first : nil
        let models = shown.map { m -> String in
            var parts: [String] = []
            if shared == nil { parts.append(cost(m)) }
            parts += shownTags(m)
            return parts.isEmpty ? m.id : "\(m.id) (\(parts.joined(separator: ", ")))"
        }
        var line = "- \(p.id) · \(p.effectivePrivacy.rawValue)"
        if let shared { line += " · \(shared)" }
        line += ": " + models.joined(separator: ", ")
        if p.models.count > shown.count { line += " +\(p.models.count - shown.count)" }
        if note, let text = notes[p.id] { line += ". Note: \(text)" }
        return line
    }

    private func tags(of models: [ModelConfig]) -> Set<String> { Set(models.flatMap(shownTags)) }

    /// Modele do pokazania: pierwsze `count` każdego dostawcy plus, wg priorytetu, pierwszy model z każdym tagiem,
    /// którego tamte nie mają. Claude wybiera model wg potrzeby (tagu), więc przycinanie nie może ukryć umiejętności.
    private func shownModels(_ providers: [ProviderConfig], count: Int) -> [[ModelConfig]] {
        var picked = providers.map { Array($0.models.prefix(count)) }
        var covered = tags(of: picked.flatMap { $0 })
        for (i, p) in providers.enumerated() {
            for m in p.models.dropFirst(count) {
                let new = tags(of: [m]).subtracting(covered)
                if !new.isEmpty { picked[i].append(m); covered.formUnion(new) }
            }
        }
        return picked
    }

    /// Katalog w `budget` znakach. Kolejno, aż się zmieści: mniej modeli na dostawcę (do jednego, plus modele
    /// z tagami, których nikt inny nie pokazuje), bez wskazówek od końca kolejki, bez dostawców od końca kolejki,
    /// najpierw tych, bez których każdy tag nadal ma model. Pominięci są wymienieni z nazwy: routing po `task`
    /// i fallback dalej z nich korzystają. Pierwszy dostawca zostaje zawsze.
    func catalog(fitting budget: Int) -> String {
        var providers: [ProviderConfig] = []
        for c in candidates where !providers.contains(where: { $0.id == c.provider.id }) { providers.append(c.provider) }
        func render(_ kept: [ProviderConfig], count: Int, notes: Int) -> String {
            var lines = zip(kept, shownModels(kept, count: count)).enumerated().map { i, pm in
                catalogLine(pm.0, models: pm.1, note: i < notes)
            }
            let skipped = providers.filter { p in !kept.contains { $0.id == p.id } }.map(\.id)
            if !skipped.isEmpty {
                lines.append("- Not listed: \(skipped.joined(separator: ", ")) (see list_models; `task` routing and fallback still use them)")
            }
            return lines.joined(separator: "\n")
        }
        for count in stride(from: Self.modelsPerProvider, through: 1, by: -1) {
            let text = render(providers, count: count, notes: providers.count)
            if text.count <= budget { return text }
        }
        for notes in stride(from: providers.count - 1, through: 0, by: -1) {
            let text = render(providers, count: 1, notes: notes)
            if text.count <= budget { return text }
        }
        let all = tags(of: providers.flatMap(\.models))
        var kept = providers
        var text = render(kept, count: 1, notes: 0)
        while kept.count > 1, text.count > budget {
            let keepsTags = kept.indices.dropFirst().reversed().first { i in
                var rest = kept
                rest.remove(at: i)
                return tags(of: rest.flatMap(\.models)) == all
            }
            kept.remove(at: keepsTags ?? kept.count - 1)
            text = render(kept, count: 1, notes: 0)
        }
        return text
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
        is a file; then check it with one `git diff`.
        - A call waits up to \(Int(DelegateRequest.syncDeadlineSeconds)) s for the reply; a slower one keeps \
        running as a job for `delegate_result`. `background: true` only to start several jobs at once.

        Every extra turn re-reads your whole context, so delegating pays only when it replaces a lot of your own \
        writing or reading: output over ~\(lineThreshold) lines (whole locale files, many fixtures, long docs), \
        or big inputs you would otherwise read (logs, long files: ask for a short report). Measured: for outputs \
        under ~200 lines delegating cost more than writing it yourself. Work like a senior with juniors: a short \
        brief (goal, constraints, output format; nothing the model can read in `files`), and an acceptance `check` \
        (tests, build, validator): failures go back to the same model, you get one line. Accept on a passing check \
        and `git diff --stat`; read the diff only if it fails or is risky; don't write your own validators. Do it \
        yourself: short outputs, edits across many files, design, debugging that needs running code.

        Choose `model` from the catalog below by what the task needs, cost (prefer free at similar quality), and \
        data region. Without `model`, the server routes by `task` tag and provider order over all configured models \
        (the catalog shows a selection), falling back on errors.
        """
        out += "\n\n" + sensitivitySection
        if let budget = dailyBudgetUSD {
            out += String(format: "\nPaid models stop for the day after $%.2f; the server enforces it.", budget)
        }
        if !agents.isEmpty {
            out += "\n\n`delegate_agent` runs a coding agent on a git repo in the background, in a sandbox. Agents in the "
                + "user's priority order (omit `agent` for the first allowed; pick another only for a reason): \(agentList). "
                + "Read mode: repo-wide searches and analysis (where X is used, what must change, a module review) instead of "
                + "reading many files yourself; spot-check its file:line claims. Write mode: well-scoped changes (translations, "
                + "tests, refactors, a feature slice) on a branch `delegate/…`, with a `check` (e.g. build and tests); "
                + "the brief can be short, the agent reads the repo itself; to act on an earlier report pass `context_jobs` "
                + "instead of retelling it. Merge on a passing check after `git diff --stat`. "
                + "Independent jobs can run in parallel; results via `delegate_result`."
        }
        if !routingGuidance.isEmpty { out += "\n\nUser's rules: " + routingGuidance }
        // Katalog na końcu: tylko on się skraca, więc nic za nim nie przepada przy ucinaniu.
        let heading = "\n\nCatalog (provider · data region · cost per 1M in/out): \n"
        return out + heading + catalog(fitting: Self.instructionsLimit - out.count - heading.count)
    }

    private var modeIntro: String {
        switch mode {
        case .conservative: "Delegate only clearly worthwhile tasks; when in doubt, do it yourself."
        case .balanced: "Use it proactively."
        case .aggressive: "Delegate by default whenever the task fits."
        }
    }

    /// Od ilu linii wyniku delegowanie się opłaca (R1: poniżej ok. 200 linii kosztowało więcej niż pisanie samemu).
    private var lineThreshold: Int {
        switch mode {
        case .conservative: 500
        case .balanced: 300
        case .aggressive: 150
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
