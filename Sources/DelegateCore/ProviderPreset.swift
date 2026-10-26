import Foundation

/// Gotowe ustawienia popularnych dostawców do „Dodaj dostawcę”. ID modeli to punkt startowy;
/// aktualne pobierzesz przez `list_remote_models` albo „Pobierz z API…”.
public struct ProviderPreset: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var kind: ProviderKind
    public var baseURL: String
    public var apiKeyEnv: String
    public var note: String?
    /// Domyślne wskazówki dla Claude'a (`ProviderConfig.guidance`).
    public var guidance: String?
    /// Gdzie zdobyć klucz (do podpowiedzi w GUI).
    public var keyURL: String?
    public var models: [ModelConfig]

    public init(id: String, title: String, kind: ProviderKind, baseURL: String = "", apiKeyEnv: String = "",
                note: String? = nil, guidance: String? = nil, keyURL: String? = nil, models: [ModelConfig] = []) {
        self.id = id
        self.title = title
        self.kind = kind
        self.baseURL = baseURL
        self.apiKeyEnv = apiKeyEnv
        self.note = note
        self.guidance = guidance
        self.keyURL = keyURL
        self.models = models
    }

    public static let all: [ProviderPreset] = [
        ProviderPreset(
            id: "mistral", title: "Mistral", kind: .openai,
            baseURL: "https://api.mistral.ai/v1", apiKeyEnv: "MISTRAL_API_KEY",
            note: "Za darmo tylko na planie Experiment w Mistral Studio; darmowy plan może pozwalać na użycie danych.",
            keyURL: "https://console.mistral.ai/api-keys",
            models: [
                ModelConfig(id: "mistral-small-latest", tags: ["general", "translate", "summarize", "fast"], cost: "free"),
                ModelConfig(id: "codestral-latest", tags: ["code"], cost: "free"),
            ]),
        ProviderPreset(
            id: "gemini", title: "Google Gemini", kind: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta", apiKeyEnv: "GEMINI_API_KEY",
            note: "Free tier zwykle pozwala dostawcy używać przesłanych danych.",
            keyURL: "https://aistudio.google.com/apikey",
            models: [
                ModelConfig(id: "gemini-flash-latest", tags: ["general", "translate", "summarize", "long-context", "fast"], cost: "free"),
                ModelConfig(id: "gemini-pro-latest", tags: ["reasoning", "code", "long-context"], cost: "paid"),
            ]),
        ProviderPreset(
            id: "deepseek", title: "DeepSeek", kind: .openai,
            baseURL: "https://api.deepseek.com/v1", apiKeyEnv: "DEEPSEEK_API_KEY",
            note: "Dane przetwarzane w Chinach. Nie wysyłaj niczego z pracy.",
            guidance: "Never send anything private or work-related: data is processed in China.",
            keyURL: "https://platform.deepseek.com/api_keys",
            models: [
                ModelConfig(id: "deepseek-chat", tags: ["general", "code"], cost: "cheap"),
                ModelConfig(id: "deepseek-reasoner", tags: ["reasoning"], cost: "cheap"),
            ]),
        ProviderPreset(
            id: "openrouter", title: "OpenRouter", kind: .openai,
            baseURL: "https://openrouter.ai/api/v1", apiKeyEnv: "OPENROUTER_API_KEY",
            keyURL: "https://openrouter.ai/settings/keys",
            models: [ModelConfig(id: "openrouter/auto", tags: ["general"], cost: "varies")]),
        ProviderPreset(
            id: "anthropic", title: "Anthropic API", kind: .anthropic,
            baseURL: "https://api.anthropic.com/v1", apiKeyEnv: "ANTHROPIC_API_KEY",
            note: "Płatne API, osobno od subskrypcji Claude.",
            keyURL: "https://console.anthropic.com/settings/keys",
            models: [ModelConfig(id: "claude-haiku-5-5", tags: ["general", "code", "fast"], cost: "paid")]),
        ProviderPreset(
            id: "ollama", title: "Ollama (lokalnie)", kind: .openai,
            baseURL: "http://localhost:11434/v1",
            note: "Model lokalny: bez klucza, dane nie opuszczają Maca.",
            guidance: "Runs locally on this Mac: fine for private content."),
        ProviderPreset(
            id: "lmstudio", title: "LM Studio (lokalnie)", kind: .openai,
            baseURL: "http://localhost:1234/v1",
            note: "Model lokalny: bez klucza, dane nie opuszczają Maca.",
            guidance: "Runs locally on this Mac: fine for private content."),
        ProviderPreset(
            id: "apple", title: "Apple na urządzeniu", kind: .foundation,
            note: "Model na urządzeniu (Apple Intelligence): za darmo, prywatnie, offline. Małe okno kontekstu, tylko krótkie zadania.",
            guidance: "On-device and private, but a small context window: only short tasks.",
            models: [ModelConfig(id: "on-device", tags: ["private", "short", "offline"], cost: "free")]),
        ProviderPreset(
            id: "custom", title: "Inny (API zgodne z OpenAI)", kind: .openai,
            baseURL: "https://api.example.com/v1", apiKeyEnv: "CUSTOM_API_KEY"),
    ]
}

extension Config {
    /// Dodaje dostawcę z presetu; przy kolizji ID dokleja numer (i dopasowuje domyślną nazwę klucza).
    /// Zwraca ID nowego dostawcy.
    @discardableResult
    public mutating func addProvider(from preset: ProviderPreset) -> String {
        var id = preset.id
        var n = 1
        while providers.contains(where: { $0.id == id }) { n += 1; id = "\(preset.id)-\(n)" }
        var keyEnv = preset.apiKeyEnv
        if id != preset.id, !keyEnv.isEmpty { keyEnv = Self.defaultKeyEnv(for: id) }
        providers.append(ProviderConfig(
            id: id, kind: preset.kind, baseURL: preset.baseURL, apiKeyEnv: keyEnv,
            note: preset.note, guidance: preset.guidance, models: preset.models.map { ModelConfig(id: $0.id, tags: $0.tags, cost: $0.cost) }))
        return id
    }

    /// `my-provider` → `MY_PROVIDER_API_KEY`.
    public static func defaultKeyEnv(for id: String) -> String {
        "\(id.uppercased().replacingOccurrences(of: "-", with: "_"))_API_KEY"
    }
}
