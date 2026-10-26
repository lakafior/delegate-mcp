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
    /// Notatka dla użytkownika (np. warunki planu).
    public var note: String?
    /// Wskazówki dla Claude'a: do czego ten dostawca jest dobry, czego tu nie wysyłać.
    /// Trafiają do instrukcji serwera MCP obok mapy modeli.
    public var guidance: String?
    /// Region danych ustawiony ręcznie; `nil` = wywnioskowany z adresu (`effectivePrivacy`).
    public var privacy: PrivacyRegion?
    /// Opcjonalny dedykowany timeout bazowy (w sekundach) dla tego dostawcy.
    public var timeoutSeconds: Double?
    public var models: [ModelConfig]

    public init(
        id: String, kind: ProviderKind, baseURL: String = "", apiKeyEnv: String = "",
        enabled: Bool = true, note: String? = nil, guidance: String? = nil, privacy: PrivacyRegion? = nil,
        timeoutSeconds: Double? = nil, models: [ModelConfig] = []
    ) {
        self.id = id
        self.kind = kind
        self.baseURL = baseURL
        self.apiKeyEnv = apiKeyEnv
        self.enabled = enabled
        self.note = note
        self.guidance = guidance
        self.privacy = privacy
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
        case enabled, note, guidance, privacy
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
        guidance = try c.decodeIfPresent(String.self, forKey: .guidance)
        // Nieznana wartość nie może zablokować wczytania configu: wtedy wnioskujemy z adresu.
        privacy = try c.decodeIfPresent(String.self, forKey: .privacy).flatMap(PrivacyRegion.init(rawValue:))
        timeoutSeconds = try c.decodeNumberIfPresent(forKey: .timeoutSeconds)
        models = try c.decodeIfPresent([ModelConfig].self, forKey: .models) ?? []
    }
}

/// Zawartość `delegate.toml`. Kolejność `providers` to priorytet fallbacku.
public struct Config: Codable, Sendable, Equatable {
    public static let defaultPersonalRegions: [PrivacyRegion] = [.local, .eu, .us]

    public var routingGuidance: String
    public var timeoutSeconds: Double
    /// Jak chętnie Claude ma delegować (ton instrukcji serwera).
    public var delegationMode: DelegationMode
    /// Regiony, do których mogą trafić zadania z `sensitivity = personal`.
    public var personalRegions: [PrivacyRegion]
    /// Dzienny limit wydatków na płatne modele w USD; po jego przekroczeniu serwer ich nie używa.
    public var dailyBudgetUSD: Double?
    public var providers: [ProviderConfig]

    public init(routingGuidance: String = "", timeoutSeconds: Double = 120, delegationMode: DelegationMode = .balanced,
                personalRegions: [PrivacyRegion] = Config.defaultPersonalRegions, dailyBudgetUSD: Double? = nil,
                providers: [ProviderConfig] = []) {
        self.routingGuidance = routingGuidance
        self.timeoutSeconds = timeoutSeconds
        self.delegationMode = delegationMode
        self.personalRegions = personalRegions
        self.dailyBudgetUSD = dailyBudgetUSD
        self.providers = providers
    }

    enum CodingKeys: String, CodingKey {
        case routingGuidance = "routing_guidance"
        case timeoutSeconds = "timeout_seconds"
        case delegationMode = "delegation_mode"
        case personalRegions = "personal_regions"
        case dailyBudgetUSD = "daily_budget_usd"
        case providers = "provider"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routingGuidance = try c.decodeIfPresent(String.self, forKey: .routingGuidance) ?? ""
        // TOML rozróżnia liczby całkowite i zmiennoprzecinkowe: `120` nie zdekoduje się jako Double.
        timeoutSeconds = try c.decodeNumberIfPresent(forKey: .timeoutSeconds) ?? 120
        delegationMode = try c.decodeIfPresent(String.self, forKey: .delegationMode)
            .flatMap(DelegationMode.init(rawValue:)) ?? .balanced
        personalRegions = try c.decodeIfPresent([String].self, forKey: .personalRegions)?
            .compactMap(PrivacyRegion.init(rawValue:)) ?? Config.defaultPersonalRegions
        dailyBudgetUSD = try c.decodeNumberIfPresent(forKey: .dailyBudgetUSD)
        providers = try c.decodeIfPresent([ProviderConfig].self, forKey: .providers) ?? []
    }

    public static func parse(_ toml: String) throws -> Config {
        try TOMLDecoder().decode(Config.self, from: toml)
    }

    /// TOML do zapisu z GUI (UTF-8, stała kolejność pól); patrz `ConfigWriter`.
    public func serialized() throws -> String {
        ConfigWriter.write(self)
    }

    /// Scalanie trójstronne: `base` to wersja, od której zaczęło GUI, `mine` to zmiany z GUI,
    /// `theirs` to plik zmieniony w międzyczasie z zewnątrz (`update_models`, edycja ręczna).
    /// Na poziomie pól i pojedynczych dostawców wygrywa strona, która coś zmieniła; przy zmianie
    /// tego samego dostawcy po obu stronach wygrywa GUI.
    public static func merge(base: Config, mine: Config, theirs: Config) -> Config {
        func pick<T: Equatable>(_ b: T, _ m: T, _ t: T) -> T { m != b ? m : t }
        var out = theirs
        out.routingGuidance = pick(base.routingGuidance, mine.routingGuidance, theirs.routingGuidance)
        out.timeoutSeconds = pick(base.timeoutSeconds, mine.timeoutSeconds, theirs.timeoutSeconds)
        out.delegationMode = pick(base.delegationMode, mine.delegationMode, theirs.delegationMode)
        out.personalRegions = pick(base.personalRegions, mine.personalRegions, theirs.personalRegions)
        out.dailyBudgetUSD = pick(base.dailyBudgetUSD, mine.dailyBudgetUSD, theirs.dailyBudgetUSD)

        func byID(_ c: Config) -> [String: ProviderConfig] {
            Dictionary(c.providers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let b = byID(base), m = byID(mine), t = byID(theirs)
        let ids = { (c: Config) in c.providers.map(\.id) }
        // Kolejność (priorytet) ze strony, która ją zmieniła; brakujące ID doklejamy na końcu.
        var order = ids(mine) != ids(base) ? ids(mine) : ids(theirs)
        for id in ids(mine) + ids(theirs) where !order.contains(id) { order.append(id) }
        out.providers = order.compactMap { id in m[id] != b[id] ? m[id] : t[id] }
        return out
    }

    /// Zmienia identyfikator dostawcy. Zwraca `false`, jeśli nazwa jest pusta lub koliduje z innym dostawcą.
    @discardableResult
    public mutating func renameProvider(from oldId: String, to rawNewId: String) -> Bool {
        let trimmed = rawNewId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == oldId { return true }
        guard !providers.contains(where: { $0.id == trimmed }) else { return false }
        guard let idx = providers.firstIndex(where: { $0.id == oldId }) else { return false }

        providers[idx].id = trimmed
        if providers[idx].apiKeyEnv == Self.defaultKeyEnv(for: oldId) {
            providers[idx].apiKeyEnv = Self.defaultKeyEnv(for: trimmed)
        }
        return true
    }
}

/// Katalog z konfiguracją, kluczami awaryjnymi (`.env`) i logiem użycia.
public struct DelegateHome: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public var configURL: URL { directory.appendingPathComponent("delegate.toml") }
    public var envURL: URL { directory.appendingPathComponent(".env") }
    public var usageURL: URL { directory.appendingPathComponent("delegate_usage.jsonl") }
    /// Kopia cennika LiteLLM (cache, odświeżany co tydzień).
    public var priceCatalogURL: URL { directory.appendingPathComponent("price_catalog.json") }

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

    /// Zapis z GUI. Komentarzy z ręcznie edytowanego TOML nie zachowuje (patrz `ConfigWriter`).
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
    /// Na start tylko model na urządzeniu; resztę użytkownik dodaje z presetów (`ProviderPreset`).
    static let toml = #"""
    # Kolejność [[provider]] = priorytet fallbacku. Dostawców dodasz w aplikacji Delegate
    # (gotowe presety) albo ręcznie tutaj. Ogólne zasady delegowania serwer podaje sam;
    # `routing_guidance` służy do Twoich reguł globalnych, a `guidance` przy dostawcy do reguł per dostawca.

    routing_guidance = ""

    timeout_seconds = 120

    [[provider]]
    id = "apple"
    type = "foundation"
    note = "Model na urządzeniu (Apple Intelligence): za darmo, prywatnie, offline. Małe okno kontekstu, tylko krótkie zadania."
    guidance = "On-device and private, but a small context window: only short tasks."

    [[provider.model]]
    id = "on-device"
    tags = ["private", "short", "offline"]
    cost = "free"
    """#
}
