import Foundation
import TOMLKit

public enum ProviderKind: String, Codable, Sendable {
    /// API zgodne z OpenAI (`/chat/completions`): Mistral, DeepSeek, OpenRouter, Ollama, LM Studio.
    case openai
    /// Gemini (`generateContent`).
    case gemini
    /// Anthropic (`/v1/messages`).
    case anthropic
    /// Model na urządzeniu (Apple Foundation Models): bez klucza, bez sieci.
    case foundation
}

public struct ModelConfig: Codable, Sendable, Equatable, Identifiable {
    /// Tożsamość wiersza w GUI; `id` modelu jest edytowalne, więc nie nadaje się na klucz widoku.
    public let uid = UUID()
    public var id: String
    public var tags: [String]
    /// Kategoria kosztu (`free`, `cheap`, `paid`, `varies`) albo `nil`, gdy podano kwoty.
    public var cost: String?
    /// Cena w USD za 1M tokenów wejścia / wyjścia (alternatywa dla kategorii).
    public var priceIn: Double?
    public var priceOut: Double?
    public var note: String?

    public init(id: String, tags: [String] = [], cost: String? = nil,
                priceIn: Double? = nil, priceOut: Double? = nil, note: String? = nil) {
        self.id = id
        self.tags = tags
        self.cost = cost
        self.priceIn = priceIn
        self.priceOut = priceOut
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case id, tags, cost, note
        case priceIn = "price_in"
        case priceOut = "price_out"
    }

    public static func == (a: ModelConfig, b: ModelConfig) -> Bool {
        a.id == b.id && a.tags == b.tags && a.cost == b.cost && a.note == b.note
            && a.priceIn == b.priceIn && a.priceOut == b.priceOut
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        cost = try c.decodeIfPresent(String.self, forKey: .cost)
        priceIn = try c.decodeNumberIfPresent(forKey: .priceIn)
        priceOut = try c.decodeNumberIfPresent(forKey: .priceOut)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    /// Czytelny koszt: kwoty, jeśli są, w przeciwnym razie kategoria.
    public var costLabel: String? {
        if priceIn != nil || priceOut != nil {
            return "$\(Self.money(priceIn)) in / $\(Self.money(priceOut)) out za 1M tok."
        }
        return cost
    }

    public static func money(_ v: Double?) -> String {
        guard let v else { return "?" }
        return String(format: "%g", v)
    }
}

extension KeyedDecodingContainer {
    /// TOML rozróżnia `1` i `1.0`; tu przyjmujemy oba.
    func decodeNumberIfPresent(forKey key: Key) throws -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        return try decodeIfPresent(Int.self, forKey: key).map(Double.init)
    }
}

public struct ProviderConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: ProviderKind
    public var baseURL: String
    /// Nazwa zmiennej / wpisu w Keychain z kluczem API.
    public var apiKeyEnv: String
    public var enabled: Bool
    public var note: String?
    /// Opcjonalny dedykowany timeout bazowy (w sekundach) dla tego dostawcy.
    public var timeoutSeconds: Double?
    public var models: [ModelConfig]

    public init(
        id: String, kind: ProviderKind, baseURL: String = "", apiKeyEnv: String = "",
        enabled: Bool = true, note: String? = nil, timeoutSeconds: Double? = nil, models: [ModelConfig] = []
    ) {
        self.id = id
        self.kind = kind
        self.baseURL = baseURL
        self.apiKeyEnv = apiKeyEnv
        self.enabled = enabled
        self.note = note
        self.timeoutSeconds = timeoutSeconds
        self.models = models
    }

    /// Czy dostawca wymaga klucza API (model na urządzeniu oraz dostawcy z pustym `apiKeyEnv` nie wymagają klucza).
    public var needsKey: Bool {
        if kind == .foundation { return false }
        return !apiKeyEnv.trimmingCharacters(in: .whitespaces).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind = "type"
        case baseURL = "base_url"
        case apiKeyEnv = "api_key_env"
        case enabled, note
        case timeoutSeconds = "timeout_seconds"
        case models = "model"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(ProviderKind.self, forKey: .kind)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiKeyEnv = try c.decodeIfPresent(String.self, forKey: .apiKeyEnv) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        note = try c.decodeIfPresent(String.self, forKey: .note)
        timeoutSeconds = try c.decodeNumberIfPresent(forKey: .timeoutSeconds)
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
        timeoutSeconds = try c.decodeNumberIfPresent(forKey: .timeoutSeconds) ?? 120
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

    /// Zapis z GUI. Uwaga: serializacja nie zachowuje komentarzy z ręcznie edytowanego TOML.
    public func save(_ config: Config) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try config.serialized().write(to: configURL, atomically: true, encoding: .utf8)
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

    [[provider]]
    id = "apple"
    type = "foundation"
    note = "Model na urządzeniu (Apple Intelligence): za darmo, prywatnie, offline. Małe okno kontekstu, tylko krótkie zadania."

    [[provider.model]]
    id = "on-device"
    tags = ["private", "short", "offline"]
    cost = "free"
    """#
}
