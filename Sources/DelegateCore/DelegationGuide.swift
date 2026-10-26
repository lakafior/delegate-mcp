import Foundation

/// Teksty, którymi serwer MCP mówi Claude'owi, kiedy i jak delegować: instrukcje serwera
/// (Claude Code i Desktop wstrzykują je do każdej sesji) oraz opis narzędzia `delegate`.
/// Generowane z configu, żeby Claude znał dostępne modele i tagi bez wołania `list_models`.
/// Po angielsku, niezależnie od języka GUI: modele najpewniej trzymają się instrukcji w tym języku.
public struct DelegationGuide: Sendable {
    /// Gotowe do użycia (włączone, z kluczem) modele wg priorytetu.
    public let candidates: [Candidate]
    public let routingGuidance: String
    /// Wskazówki użytkownika per dostawca (tylko gotowi), w kolejności priorytetu.
    public let providerGuidance: [(id: String, text: String)]
    public let mode: DelegationMode
    public let personalRegions: [PrivacyRegion]
    public let dailyBudgetUSD: Double?

    public init(config: Config, isReady: (ProviderConfig) -> Bool) {
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

    /// Tagi, których nie pokazujemy Claude'owi: `delegate` wysyła tylko tekst, więc „vision” by mylił.
    static let hiddenTags: Set<String> = ["vision"]

    /// Tagi w kolejności pierwszego wystąpienia (czyli wg priorytetu dostawców).
    public var tags: [String] {
        var seen = Set<String>(Self.hiddenTags)
        return candidates.flatMap { $0.model.tags.map { $0.lowercased() } }.filter { seen.insert($0).inserted }
    }

    private func costHint(_ c: Candidate) -> String {
        if c.provider.kind == .foundation { return "on-device" }
        if let cost = c.model.cost { return cost }
        if c.model.priceIn != nil || c.model.priceOut != nil {
            return "$\(ModelConfig.money(c.model.priceIn))/$\(ModelConfig.money(c.model.priceOut)) per 1M"
        }
        return ""
    }

    /// Krótka mapa routingu: `- translate: mistral/mistral-small-latest (free), gemini/...`.
    var routingTable: String {
        tags.map { tag in
            let refs = candidates.filter { $0.model.tags.contains { $0.lowercased() == tag } }.prefix(3).map { c in
                let hint = costHint(c)
                return hint.isEmpty ? c.ref : "\(c.ref) (\(hint))"
            }
            return "- \(tag): \(refs.joined(separator: ", "))"
        }.joined(separator: "\n")
    }

    // MARK: instrukcje serwera

    public var serverInstructions: String {
        guard !candidates.isEmpty else {
            return """
            The `delegate` server has no usable models right now (no provider with an API key is enabled). \
            Do not call `delegate`; tell the user to add a provider in the Delegate app if they ask about it.
            """
        }
        var out = """
        `delegate` hands self-contained tasks to cheaper models (free tiers, local models). The user's Claude \
        usage limits are finite, so every task you delegate instead of writing yourself saves them. \(modeIntro)

        Delegate when all of these hold:
        - the task fits in one prompt: the other model sees ONLY your prompt (no files, tools, or conversation), so paste all needed context;
        - you can quickly check the result;
        - no secrets or credentials are involved, and personal or work data is sent only with the right `sensitivity` (below).

        Good fits: translating text; summarizing pasted text, logs, or docs; first drafts (emails, descriptions, \
        READMEs, release notes, commit messages); rewriting, reformatting, or extracting data from text; generating \
        many variants, test data, or boilerplate; a second opinion on a self-contained code snippet. The longer the \
        expected output, the more delegation saves. Rule of thumb: if you are about to write more than ~\(wordThreshold) \
        words of prose or repetitive content that doesn't depend on files only you can see, delegate it.

        Do it yourself: design decisions, debugging, changes that need repository or tool access, security-sensitive \
        work, and anything you can answer in a sentence or two.

        How: call `delegate` directly with a `task` tag (no need to call `list_models` first). Ask for the exact output \
        format you need. The reply header names the model that answered. Review the result before using it; if it is \
        wrong or weak, fix it or do the task yourself, and don't present delegated output as verified without checking.
        """
        out += "\n\n" + sensitivitySection
        if let budget = dailyBudgetUSD {
            out += String(format: "\n\nPaid models share a daily budget of $%.2f. Once it is spent, the server uses only free models; no need to track it yourself.", budget)
        }
        out += "\n\nAvailable task tags → models (tried in this order, with automatic fallback):\n" + routingTable
        if !providerGuidance.isEmpty {
            out += "\n\nUser's notes per provider (pick a provider with `model` when a note fits the task):\n"
                + providerGuidance.map { "- \($0.id): \($0.text)" }.joined(separator: "\n")
        }
        if !routingGuidance.isEmpty {
            out += "\n\nUser's routing rules (follow them):\n" + routingGuidance
        }
        return out
    }

    private var modeIntro: String {
        switch mode {
        case .conservative:
            "Delegate only clearly long, self-contained text tasks where the savings are obvious; when in doubt, do it yourself."
        case .balanced:
            "Use it proactively."
        case .aggressive:
            "Delegate by default: whenever the criteria below hold, delegate even short drafts and rewrites instead of writing them yourself."
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
        var s = """
        Data sensitivity (the server enforces it; set `sensitivity` on every call that carries such data):
        - `public` (default): nothing personal; any provider.
        - `personal`: personal or work data without secrets; only providers in these regions: \(regions).
        """
        s += local.isEmpty
            ? "\n- `private`: must stay on this Mac. No local model is ready, so do private tasks yourself."
            : "\n- `private`: must stay on this Mac; only local models (\(local.joined(separator: ", "))), with small context windows."
        return s
    }

    // MARK: opis narzędzia `delegate`

    public var toolDescription: String {
        var d = """
        Send a self-contained task to a cheaper model to save the user's Claude usage limits. Use for translation, \
        summarizing pasted text, first drafts, rewriting/extraction, bulk generation, or a second opinion on a code \
        snippet. The model sees ONLY the prompt (no files, tools, or conversation): include all context. Pick a `task` \
        tag; a specific `model` is optional. Falls back to the next model on errors. Never send secrets; mark personal \
        or work data with `sensitivity`. Check the result before using it.
        """
        if candidates.isEmpty { d += " No models are currently available." }
        return d
    }

    /// Opis parametru `model` z listą dostępnych modeli (ucięty, żeby nie zapchać kontekstu).
    public var modelParameterDescription: String {
        let refs = candidates.map(\.ref)
        let shown = refs.prefix(25).joined(separator: ", ")
        let more = refs.count > 25 ? ", … (\(refs.count - 25) more, see list_models)" : ""
        return "Optional specific model as provider/model. Available: \(shown)\(more). Leave empty to route by `task`."
    }
}

extension DelegateService {
    public func guide(config: Config) -> DelegationGuide {
        DelegationGuide(config: config) { status(of: $0) == .ready }
    }
}
