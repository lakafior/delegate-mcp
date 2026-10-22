import Foundation
import TOMLKit

public enum ProviderKind: String, Codable, Sendable {
    /// API zgodne z OpenAI (`/chat/completions`): Mistral, DeepSeek, OpenRouter.
    case openai
    /// Gemini (`generateContent`).
    case gemini
}

public struct ModelConfig: Codable, Sendable, Equatable {
    public var id: String
    public var tags: [String]
    public var cost: String?
    public var note: String?

    public init(id: String, tags: [String] = [], cost: String? = nil, note: String? = nil) {
        self.id = id
        self.tags = tags
        self.cost = cost
        self.note = note
    }

    enum CodingKeys: String, CodingKey { case id, tags, cost, note }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        cost = try c.decodeIfPresent(String.self, forKey: .cost)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

public struct ProviderConfig: Codable, Sendable, Equatable {
    public var id: String
    public var kind: ProviderKind
    public var baseURL: String
    /// Nazwa zmiennej / wpisu w Keychain z kluczem API.
    public var apiKeyEnv: String
    public var enabled: Bool
    public var note: String?
    public var models: [ModelConfig]

    public init(
        id: String, kind: ProviderKind, baseURL: String, apiKeyEnv: String,
        enabled: Bool = true, note: String? = nil, models: [ModelConfig] = []
    ) {
        self.id = id
        self.kind = kind
        self.baseURL = baseURL
        self.apiKeyEnv = apiKeyEnv
        self.enabled = enabled
        self.note = note
        self.models = models
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind = "type"
        case baseURL = "base_url"
        case apiKeyEnv = "api_key_env"
        case enabled, note
        case models = "model"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(ProviderKind.self, forKey: .kind)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        apiKeyEnv = try c.decode(String.self, forKey: .apiKeyEnv)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        note = try c.decodeIfPresent(String.self, forKey: .note)
        models = try c.decodeIfPresent([ModelConfig].self, forKey: .models) ?? []
    }
}

/// Zawartość `delegate.toml`. Kolejność `providers` to priorytet fallbacku.
public struct Config: Codable, Sendable, Equatable {
    public var routingGuidance: String
    public var timeoutSeconds: Double
    public var providers: [ProviderConfig]

    public init(routingGuidance: String = "", timeoutSeconds: Double = 120, providers: [ProviderConfig] = []) {
        self.routingGuidance = routingGuidance
        self.timeoutSeconds = timeoutSeconds
        self.providers = providers
    }

    enum CodingKeys: String, CodingKey {
        case routingGuidance = "routing_guidance"
        case timeoutSeconds = "timeout_seconds"
        case providers = "provider"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routingGuidance = try c.decodeIfPresent(String.self, forKey: .routingGuidance) ?? ""
        // TOML rozróżnia liczby całkowite i zmiennoprzecinkowe: `120` nie zdekoduje się jako Double.
        if let d = try? c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) {
            timeoutSeconds = d
        } else if let i = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) {
            timeoutSeconds = Double(i)
        } else {
            timeoutSeconds = 120
        }
        providers = try c.decodeIfPresent([ProviderConfig].self, forKey: .providers) ?? []
    }

    public static func parse(_ toml: String) throws -> Config {
        try TOMLDecoder().decode(Config.self, from: toml)
    }

    public func serialized() throws -> String {
        try TOMLEncoder().encode(self)
    }
}

/// Katalog z konfiguracją, kluczami awaryjnymi (`.env`) i logiem użycia.
public struct DelegateHome: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public var configURL: URL { directory.appendingPathComponent("delegate.toml") }
    public var envURL: URL { directory.appendingPathComponent(".env") }
    public var usageURL: URL { directory.appendingPathComponent("delegate_usage.jsonl") }

    /// `$DELEGATE_HOME` albo `~/Library/Application Support/Delegate`.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> DelegateHome {
        if let path = environment["DELEGATE_HOME"], !path.isEmpty {
            return DelegateHome(directory: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DelegateHome(directory: support.appendingPathComponent("Delegate"))
    }

    /// Wczytuje config przy każdym wywołaniu; brak pliku tworzy domyślny.
    public func loadConfig() throws -> Config {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            try writeDefaultConfig()
        }
        return try Config.parse(String(contentsOf: configURL, encoding: .utf8))
    }

    @discardableResult
    public func writeDefaultConfig(overwrite: Bool = false) throws -> Bool {
        if !overwrite, FileManager.default.fileExists(atPath: configURL.path) { return false }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try DefaultConfig.toml.write(to: configURL, atomically: true, encoding: .utf8)
        return true
    }
}

enum DefaultConfig {
    static let toml = #"""
    # Kolejność [[provider]] = priorytet fallbacku. ID modeli często się zmieniają;
    # użyj list_remote_models, żeby sprawdzić aktualne.

    routing_guidance = """
    Deleguj zadania samowystarczalne: masowe generowanie, tłumaczenia, pierwsze drafty,
    streszczenia wklejonego tekstu, druga opinia o fragmencie kodu.
    Wynik zawsze weryfikuj. Nie wysyłaj danych z pracy, sekretów ani danych osobowych.
    Do DeepSeeka nie wysyłaj niczego prywatnego (dane przetwarzane w Chinach).
    """

    timeout_seconds = 120

    [[provider]]
    id = "mistral"
    type = "openai"
    base_url = "https://api.mistral.ai/v1"
    api_key_env = "MISTRAL_API_KEY"
    note = "Za darmo tylko na planie Experiment w Mistral Studio; darmowy plan może pozwalać na użycie danych."

    [[provider.model]]
    id = "mistral-small-latest"
    tags = ["general", "translate", "summarize"]
    cost = "free"

    [[provider.model]]
    id = "codestral-latest"
    tags = ["code"]
    cost = "free"

    [[provider]]
    id = "gemini"
    type = "gemini"
    base_url = "https://generativelanguage.googleapis.com/v1beta"
    api_key_env = "GEMINI_API_KEY"
    note = "Free tier zwykle pozwala dostawcy używać przesłanych danych."

    [[provider.model]]
    id = "gemini-flash-latest"
    tags = ["general", "translate", "summarize", "long-context"]
    cost = "free"

    [[provider.model]]
    id = "gemini-pro-latest"
    tags = ["reasoning", "code"]
    cost = "paid"

    [[provider]]
    id = "deepseek"
    type = "openai"
    base_url = "https://api.deepseek.com/v1"
    api_key_env = "DEEPSEEK_API_KEY"
    note = "Dane przetwarzane w Chinach. Nie wysyłaj niczego z pracy."

    [[provider.model]]
    id = "deepseek-chat"
    tags = ["general", "code"]
    cost = "cheap"

    [[provider.model]]
    id = "deepseek-reasoner"
    tags = ["reasoning"]
    cost = "cheap"

    [[provider]]
    id = "openrouter"
    type = "openai"
    base_url = "https://openrouter.ai/api/v1"
    api_key_env = "OPENROUTER_API_KEY"

    [[provider.model]]
    id = "openrouter/auto"
    tags = ["general"]
    cost = "varies"
    """#
}
