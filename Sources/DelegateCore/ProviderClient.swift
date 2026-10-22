import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse("brak odpowiedzi HTTP") }
        return (data, http)
    }
}

public enum ProviderError: Error, CustomStringConvertible, Sendable {
    case http(status: Int, body: String)
    case network(String)
    case badResponse(String)
    case missingKey(String)

    public var description: String {
        switch self {
        case .http(let status, let body): "HTTP \(status): \(body)"
        case .network(let m): "sieć: \(m)"
        case .badResponse(let m): "zła odpowiedź: \(m)"
        case .missingKey(let name): "brak klucza \(name)"
        }
    }
}

public struct ChatRequest: Sendable {
    public var prompt: String
    public var system: String?
    public var temperature: Double?
    public var maxTokens: Int?

    public init(prompt: String, system: String? = nil, temperature: Double? = nil, maxTokens: Int? = nil) {
        self.prompt = prompt
        self.system = system
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

public struct ChatReply: Sendable, Equatable {
    public var text: String
    public var inputTokens: Int?
    public var outputTokens: Int?
}

struct ProviderClient {
    let transport: any HTTPTransport
    let timeout: TimeInterval

    func chat(provider: ProviderConfig, model: String, apiKey: String, request: ChatRequest) async throws -> ChatReply {
        switch provider.kind {
        case .openai: try await chatOpenAI(provider, model, apiKey, request)
        case .gemini: try await chatGemini(provider, model, apiKey, request)
        case .foundation: throw ProviderError.badResponse("model na urządzeniu obsługuje DelegateService")
        }
    }

    func listModels(provider: ProviderConfig, apiKey: String) async throws -> [String] {
        try await listModelInfo(provider: provider, apiKey: apiKey).map(\.id)
    }

    /// Lista modeli z metadanymi, które dostawca udostępnia (zdolności, kontekst, ceny).
    func listModelInfo(provider: ProviderConfig, apiKey: String) async throws -> [ModelInfo] {
        guard provider.kind != .foundation else { return [ModelInfo(id: "on-device", contextLength: 4096, priceIn: 0, priceOut: 0)] }
        var req = try makeRequest(url: join(provider.baseURL, "models"), method: "GET")
        authorize(&req, provider: provider, apiKey: apiKey)
        let json = try await perform(req)

        switch provider.kind {
        case .openai:
            return (json["data"] as? [[String: Any]] ?? []).compactMap(Self.openAIInfo).sorted { $0.id < $1.id }
        case .gemini:
            return (json["models"] as? [[String: Any]] ?? []).compactMap(Self.geminiInfo).sorted { $0.id < $1.id }
        case .foundation:
            return []
        }
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// Mistral podaje `capabilities` i `max_context_length`, OpenRouter `architecture`, `pricing`
    /// (USD za token jako tekst) i `supported_parameters`; DeepSeek tylko ID.
    private static func openAIInfo(_ m: [String: Any]) -> ModelInfo? {
        guard let id = m["id"] as? String else { return nil }
        let caps = m["capabilities"] as? [String: Any]
        let params = m["supported_parameters"] as? [String] ?? []
        let arch = m["architecture"] as? [String: Any]
        let inputs = arch?["input_modalities"] as? [String] ?? []
        let pricing = m["pricing"] as? [String: Any]

        var chat: Bool? = nil
        if let c = caps?["completion_chat"] as? Bool { chat = c }
        let perMillion: (Any?) -> Double? = { number($0).map { $0 * 1_000_000 } }
        return ModelInfo(
            id: id,
            contextLength: (number(m["max_context_length"]) ?? number(m["context_length"])).map(Int.init),
            priceIn: perMillion(pricing?["prompt"]),
            priceOut: perMillion(pricing?["completion"]),
            vision: (caps?["vision"] as? Bool) == true || inputs.contains("image"),
            reasoning: params.contains("reasoning") || params.contains("include_reasoning"),
            tools: (caps?["function_calling"] as? Bool) == true || params.contains("tools"),
            isChat: chat
        )
    }

    private static func geminiInfo(_ m: [String: Any]) -> ModelInfo? {
        let methods = m["supportedGenerationMethods"] as? [String] ?? []
        guard methods.isEmpty || methods.contains("generateContent"), let name = m["name"] as? String else { return nil }
        return ModelInfo(
            id: name.hasPrefix("models/") ? String(name.dropFirst(7)) : name,
            contextLength: number(m["inputTokenLimit"]).map(Int.init),
            reasoning: (m["thinking"] as? Bool) == true
        )
    }

    // MARK: OpenAI-compatible

    private func chatOpenAI(_ p: ProviderConfig, _ model: String, _ key: String, _ r: ChatRequest) async throws -> ChatReply {
        var messages: [[String: String]] = []
        if let s = r.system, !s.isEmpty { messages.append(["role": "system", "content": s]) }
        messages.append(["role": "user", "content": r.prompt])
        var body: [String: Any] = ["model": model, "messages": messages]
        if let t = r.temperature { body["temperature"] = t }
        if let m = r.maxTokens { body["max_tokens"] = m }

        var req = try makeRequest(url: join(p.baseURL, "chat/completions"), method: "POST")
        authorize(&req, provider: p, apiKey: key)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await perform(req)

        let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        guard let text = message?["content"] as? String, !text.isEmpty else {
            throw ProviderError.badResponse("pusta odpowiedź modelu")
        }
        let usage = json["usage"] as? [String: Any]
        return ChatReply(text: text,
                         inputTokens: usage?["prompt_tokens"] as? Int,
                         outputTokens: usage?["completion_tokens"] as? Int)
    }

    // MARK: Gemini

    private func chatGemini(_ p: ProviderConfig, _ model: String, _ key: String, _ r: ChatRequest) async throws -> ChatReply {
        var body: [String: Any] = ["contents": [["role": "user", "parts": [["text": r.prompt]]]]]
        if let s = r.system, !s.isEmpty { body["systemInstruction"] = ["parts": [["text": s]]] }
        var gen: [String: Any] = [:]
        if let t = r.temperature { gen["temperature"] = t }
        if let m = r.maxTokens { gen["maxOutputTokens"] = m }
        if !gen.isEmpty { body["generationConfig"] = gen }

        var req = try makeRequest(url: join(p.baseURL, "models/\(model):generateContent"), method: "POST")
        authorize(&req, provider: p, apiKey: key)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await perform(req)

        let content = (json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any]
        let text = (content?["parts"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw ProviderError.badResponse("pusta odpowiedź modelu") }
        let usage = json["usageMetadata"] as? [String: Any]
        return ChatReply(text: text,
                         inputTokens: usage?["promptTokenCount"] as? Int,
                         outputTokens: usage?["candidatesTokenCount"] as? Int)
    }

    // MARK: wspólne

    private func join(_ base: String, _ path: String) -> String {
        base.hasSuffix("/") ? base + path : base + "/" + path
    }

    private func makeRequest(url: String, method: String) throws -> URLRequest {
        guard let u = URL(string: url) else { throw ProviderError.badResponse("zły URL: \(url)") }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    private func authorize(_ req: inout URLRequest, provider: ProviderConfig, apiKey: String) {
        switch provider.kind {
        case .openai: req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .gemini: req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        case .foundation: break
        }
    }

    private func perform(_ req: URLRequest) async throws -> [String: Any] {
        let data: Data, http: HTTPURLResponse
        do { (data, http) = try await transport.send(req) }
        catch let e as ProviderError { throw e }
        catch { throw ProviderError.network(error.localizedDescription) }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(300), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
            throw ProviderError.http(status: http.statusCode, body: body)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse("odpowiedź nie jest obiektem JSON")
        }
        return json
    }
}
