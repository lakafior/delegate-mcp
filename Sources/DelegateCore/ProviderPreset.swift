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
    /// Region zapisywany jawnie przy dodaniu (`ProviderConfig.privacy`), żeby nie zależał od portu w adresie.
    public var privacy: PrivacyRegion?
    /// Region trzeba wybrać przy dodaniu (gateway: dane idą tam, dokąd on je prześle, adres tego nie mówi).
    public var asksRegion: Bool
    public var models: [ModelConfig]

    public init(id: String, title: String, kind: ProviderKind, baseURL: String = "", apiKeyEnv: String = "",
                note: String? = nil, guidance: String? = nil, keyURL: String? = nil, privacy: PrivacyRegion? = nil,
                asksRegion: Bool = false, models: [ModelConfig] = []) {
        self.id = id
        self.title = title
        self.kind = kind
        self.baseURL = baseURL
        self.apiKeyEnv = apiKeyEnv
        self.note = note
        self.guidance = guidance
        self.keyURL = keyURL
        self.privacy = privacy
        self.asksRegion = asksRegion
        self.models = models
    }

    public static let all: [ProviderPreset] = [
        ProviderPreset(
            id: "mistral", title: "Mistral", kind: .openai,
            baseURL: "https://api.mistral.ai/v1", apiKeyEnv: "MISTRAL_API_KEY",
            note: "Free only on the Experiment plan in Mistral Studio; the free plan may allow use of your data.",
            keyURL: "https://console.mistral.ai/api-keys",
            models: [
                ModelConfig(id: "mistral-small-latest", tags: ["general", "translate", "summarize", "fast"], cost: "free"),
                ModelConfig(id: "codestral-latest", tags: ["code"], cost: "free"),
            ]),
        ProviderPreset(
            id: "gemini", title: "Google Gemini", kind: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta", apiKeyEnv: "GEMINI_API_KEY",
            note: "The free tier usually lets the provider use submitted data.",
            keyURL: "https://aistudio.google.com/apikey",
            models: [
                ModelConfig(id: "gemini-flash-latest", tags: ["general", "translate", "summarize", "long-context", "fast"], cost: "free"),
                ModelConfig(id: "gemini-pro-latest", tags: ["reasoning", "code", "long-context"], cost: "paid"),
            ]),
        ProviderPreset(
            id: "deepseek", title: "DeepSeek", kind: .openai,
            baseURL: "https://api.deepseek.com/v1", apiKeyEnv: "DEEPSEEK_API_KEY",
            note: "Data is processed in China. Don't send anything work-related.",
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
            id: "groq", title: "Groq", kind: .openai,
            baseURL: "https://api.groq.com/openai/v1", apiKeyEnv: "GROQ_API_KEY",
            note: "Free plan without a card: per model about 30 requests/min, 1,000 a day and 8K tokens/min, so short tasks only. The free plan may allow use of your data.",
            guidance: "Very fast open models, small free limits (8K tokens/min): short tasks.",
            keyURL: "https://console.groq.com/keys", privacy: .us,
            models: [
                ModelConfig(id: "openai/gpt-oss-120b", tags: ["general", "code", "fast"], cost: "free"),
                ModelConfig(id: "openai/gpt-oss-20b", tags: ["general", "fast", "short"], cost: "free"),
            ]),
        ProviderPreset(
            id: "nvidia", title: "NVIDIA NIM", kind: .openai,
            baseURL: "https://integrate.api.nvidia.com/v1", apiKeyEnv: "NVIDIA_API_KEY",
            note: "Free trial inference (build.nvidia.com) with a request-per-minute limit and no token cap; under NVIDIA's API Trial Terms.",
            guidance: "Free trial endpoint with many open models; rate-limited per minute.",
            keyURL: "https://build.nvidia.com", privacy: .us,
            models: [
                ModelConfig(id: "deepseek-ai/deepseek-v4.1-flash", tags: ["general", "code"], cost: "free"),
                ModelConfig(id: "nvidia/nemotron-3-super-120b-a12b", tags: ["general", "reasoning"], cost: "free"),
            ]),
        ProviderPreset(
            id: "sambanova", title: "SambaNova", kind: .openai,
            baseURL: "https://api.sambanova.ai/v1", apiKeyEnv: "SAMBANOVA_API_KEY",
            note: "Free tier while no payment method is linked: per model 20 requests/min, 20 a day and 200K tokens a day.",
            guidance: "Strong open models free, but only 20 requests a day per model.",
            keyURL: "https://cloud.sambanova.ai/apis", privacy: .us,
            models: [
                ModelConfig(id: "DeepSeek-V3.1", tags: ["general", "code"], cost: "free"),
                ModelConfig(id: "gpt-oss-120b", tags: ["general", "reasoning"], cost: "free"),
            ]),
        ProviderPreset(
            id: "cloudflare", title: "Cloudflare Workers AI", kind: .openai,
            baseURL: "https://api.cloudflare.com/client/v4/accounts/ACCOUNT_ID/ai/v1", apiKeyEnv: "CLOUDFLARE_AI_TOKEN",
            note: "Replace ACCOUNT_ID in the address with your account ID (Workers AI page → Use REST API, where you also create the token). Free: 10,000 Neurons a day, roughly 130K output tokens on a small model. No model list over the API: add model IDs by hand.",
            guidance: "Small free daily allowance: short tasks on small models.",
            keyURL: "https://dash.cloudflare.com/?to=/:account/ai/workers-ai", privacy: .us,
            models: [
                ModelConfig(id: "@cf/openai/gpt-oss-20b", tags: ["general", "short"], cost: "free"),
                ModelConfig(id: "@cf/mistralai/mistral-small-3.1-24b-instruct", tags: ["general", "translate", "short"], cost: "free"),
            ]),
        ProviderPreset(
            id: "anthropic", title: "Anthropic API", kind: .anthropic,
            baseURL: "https://api.anthropic.com/v1", apiKeyEnv: "ANTHROPIC_API_KEY",
            note: "Paid API, separate from the Claude subscription.",
            keyURL: "https://console.anthropic.com/settings/keys",
            models: [ModelConfig(id: "claude-haiku-5-5", tags: ["general", "code", "fast"], cost: "paid")]),
        ProviderPreset(
            id: "ollama", title: "Ollama (local)", kind: .openai,
            baseURL: "http://localhost:11434/v1",
            note: "Local model: no key needed, data never leaves the Mac.",
            guidance: "Runs locally on this Mac: fine for private content.",
            privacy: .local),
        ProviderPreset(
            id: "lmstudio", title: "LM Studio (local)", kind: .openai,
            baseURL: "http://localhost:1234/v1",
            note: "Local model: no key needed, data never leaves the Mac.",
            guidance: "Runs locally on this Mac: fine for private content.",
            privacy: .local),
        ProviderPreset(
            id: "gateway", title: "Gateway (OmniRoute / LiteLLM)", kind: .openai,
            baseURL: "http://localhost:20128/v1", apiKeyEnv: "GATEWAY_API_KEY",
            note: "One OpenAI-compatible endpoint in front of many providers. Its region is wherever it forwards your data, so pick the strictest one it can use. OmniRoute listens on port 20128, LiteLLM on 4000.",
            guidance: "Gateway that picks the upstream model itself: quality and speed vary.",
            asksRegion: true,
            models: [ModelConfig(id: "auto/cheap", tags: ["general"], cost: "varies")]),
        ProviderPreset(
            id: "apple", title: "Apple on-device", kind: .foundation,
            note: "On-device model (Apple Intelligence): free, private, offline. Small context window, short tasks only.",
            guidance: "On-device and private, but a small context window: only short tasks.",
            models: [ModelConfig(id: "on-device", tags: ["private", "short", "offline"], cost: "free")]),
        ProviderPreset(
            id: "custom", title: "Other (OpenAI-compatible API)", kind: .openai,
            baseURL: "https://api.example.com/v1", apiKeyEnv: "CUSTOM_API_KEY"),
    ]
}

extension Config {
    /// Dodaje dostawcę z presetu; przy kolizji ID dokleja numer (i dopasowuje domyślną nazwę klucza).
    /// `privacy` (wybór użytkownika) wygrywa z regionem presetu. Zwraca ID nowego dostawcy.
    @discardableResult
    public mutating func addProvider(from preset: ProviderPreset, privacy: PrivacyRegion? = nil) -> String {
        var id = preset.id
        var n = 1
        while providers.contains(where: { $0.id == id }) { n += 1; id = "\(preset.id)-\(n)" }
        var keyEnv = preset.apiKeyEnv
        if id != preset.id, !keyEnv.isEmpty { keyEnv = Self.defaultKeyEnv(for: id) }
        providers.append(ProviderConfig(
            id: id, kind: preset.kind, baseURL: preset.baseURL, apiKeyEnv: keyEnv,
            note: preset.note, guidance: preset.guidance, privacy: privacy ?? preset.privacy, models: preset.models.map { ModelConfig(id: $0.id, tags: $0.tags, cost: $0.cost) }))
        return id
    }

    /// `my-provider` → `MY_PROVIDER_API_KEY`.
    public static func defaultKeyEnv(for id: String) -> String {
        "\(id.uppercased().replacingOccurrences(of: "-", with: "_"))_API_KEY"
    }
}
