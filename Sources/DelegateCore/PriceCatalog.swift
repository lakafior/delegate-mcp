import Foundation

/// Cennik modeli z publicznego katalogu LiteLLM (`model_prices_and_context_window.json`).
/// Uzupełnia ceny dla dostawców, których API ich nie podaje (Mistral, Gemini, DeepSeek, Anthropic, OpenAI…).
public struct PriceCatalog: Sendable {
    public static let sourceURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    public static let sourceName = "LiteLLM"

    public struct Price: Sendable, Equatable {
        /// USD za 1M tokenów.
        public var input: Double
        public var output: Double
        /// `litellm_provider` z katalogu, np. `mistral`, `anthropic`.
        public var provider: String?
    }

    let prices: [String: Price]

    init(prices: [String: Price]) { self.prices = prices }

    /// Wpisy bez cen tokenów (obrazy, audio, `sample_spec`) pomijamy.
    public static func parse(_ data: Data) throws -> PriceCatalog {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DelegateError(description: "\(sourceName) price list is not a JSON object")
        }
        var prices: [String: Price] = [:]
        for (key, value) in root {
            guard let entry = value as? [String: Any],
                  let input = (entry["input_cost_per_token"] as? NSNumber)?.doubleValue,
                  let output = (entry["output_cost_per_token"] as? NSNumber)?.doubleValue else { continue }
            prices[key] = Price(input: input * 1_000_000, output: output * 1_000_000,
                                provider: entry["litellm_provider"] as? String)
        }
        return PriceCatalog(prices: prices)
    }

    /// Nazwa dostawcy w katalogu wg hosta z `base_url`; `nil`, gdy katalog go nie zna.
    static func catalogProvider(forBaseURL baseURL: String) -> String? {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return nil }
        let known: [(String, String)] = [
            ("api.mistral.ai", "mistral"),
            ("generativelanguage.googleapis.com", "gemini"),
            ("api.deepseek.com", "deepseek"),
            ("api.anthropic.com", "anthropic"),
            ("api.openai.com", "openai"),
            ("api.x.ai", "xai"),
            ("api.groq.com", "groq"),
            ("api.together.xyz", "together_ai"),
            ("api.perplexity.ai", "perplexity"),
        ]
        return known.first { host == $0.0 || host.hasSuffix("." + $0.0) }?.1
    }

    /// Cena modelu u danego dostawcy: najpierw `dostawca/model`, potem samo ID (tak katalog trzyma
    /// np. modele Anthropic i OpenAI), ale tylko gdy wpis należy do tego dostawcy.
    public func price(for modelID: String, provider: ProviderConfig) -> Price? {
        guard let name = Self.catalogProvider(forBaseURL: provider.baseURL) else { return nil }
        if let p = prices["\(name)/\(modelID)"] { return p }
        if let p = prices[modelID], p.provider == name { return p }
        return nil
    }
}

/// Lokalna kopia cennika w katalogu domowym. Odświeżana co tydzień, a wcześniej (najwyżej raz na
/// `missRefreshInterval`), gdy w kopii brakuje ceny modelu: nowe modele trafiają do LiteLLM po kilku dniach.
/// Przy braku sieci używa starej kopii.
public struct PriceCatalogStore: Sendable {
    let cacheURL: URL
    let transport: any HTTPTransport
    let maxAge: TimeInterval
    let missRefreshInterval: TimeInterval

    public init(cacheURL: URL, transport: any HTTPTransport = URLSessionTransport(),
                maxAge: TimeInterval = 7 * 24 * 3600, missRefreshInterval: TimeInterval = 24 * 3600) {
        self.cacheURL = cacheURL
        self.transport = transport
        self.maxAge = maxAge
        self.missRefreshInterval = missRefreshInterval
    }

    /// Kiedy pobrano obecną kopię (`nil`: jeszcze nigdy).
    public var cacheDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
    }

    private var cacheAge: TimeInterval? { cacheDate.map { Date().timeIntervalSince($0) } }

    /// Czy przy brakującej cenie warto pobrać cennik od nowa (kopia starsza niż `missRefreshInterval`).
    public var canRefreshOnMiss: Bool { (cacheAge ?? .infinity) >= missRefreshInterval }

    /// `nil`, gdy nie ma ani świeżego pobrania, ani kopii (wtedy po prostu nie uzupełniamy cen).
    public func load(forceRefresh: Bool = false) async -> PriceCatalog? {
        if !forceRefresh, let age = cacheAge, age < maxAge, let cached = readCache() { return cached }
        if let fresh = await download() { return fresh }
        return readCache()
    }

    private func readCache() -> PriceCatalog? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? PriceCatalog.parse(data)
    }

    private func download() async -> PriceCatalog? {
        var req = URLRequest(url: PriceCatalog.sourceURL, timeoutInterval: 30)
        req.httpMethod = "GET"
        guard let (data, http) = try? await transport.send(req), (200..<300).contains(http.statusCode),
              let catalog = try? PriceCatalog.parse(data) else { return nil }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
        return catalog
    }
}
