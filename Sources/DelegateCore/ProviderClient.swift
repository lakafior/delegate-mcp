import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse("no HTTP response") }
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
        case .network(let m): "network: \(m)"
        case .badResponse(let m): "bad response: \(m)"
        case .missingKey(let name): "missing key \(name)"
        }
    }
}

public struct ChatRequest: Sendable {
    public var prompt: String
    public var system: String?
    public var temperature: Double?
    public var maxTokens: Int?
    public var jsonMode: Bool

    public init(prompt: String, system: String? = nil, temperature: Double? = nil, maxTokens: Int? = nil, jsonMode: Bool = false) {
        self.prompt = prompt
        self.system = system
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.jsonMode = jsonMode
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
        case .anthropic: try await chatAnthropic(provider, model, apiKey, request)
        case .foundation: throw ProviderError.badResponse("the on-device model is handled by DelegateService")
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
        case .anthropic:
            return (json["data"] as? [[String: Any]] ?? []).compactMap(Self.anthropicInfo).sorted { $0.id < $1.id }
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
    /// (USD za token jako tekst) i `supported_parameters`, Venice `model_spec` (ceny już za 1M tokenów,
    /// zdolności, `type`); DeepSeek tylko ID.
    private static func openAIInfo(_ m: [String: Any]) -> ModelInfo? {
        guard let id = m["id"] as? String else { return nil }
        let caps = m["capabilities"] as? [String: Any]
        let params = m["supported_parameters"] as? [String] ?? []
        let arch = m["architecture"] as? [String: Any]
        let inputs = arch?["input_modalities"] as? [String] ?? []
        let pricing = m["pricing"] as? [String: Any]

        let spec = m["model_spec"] as? [String: Any]
        let specCaps = spec?["capabilities"] as? [String: Any]
        let specPricing = spec?["pricing"] as? [String: Any]
        let usd: (String) -> Double? = { number((specPricing?[$0] as? [String: Any])?["usd"]) }

        var chat: Bool? = nil
        if let c = caps?["completion_chat"] as? Bool { chat = c }
        if let type = m["type"] as? String { chat = type == "text" }
        let perMillion: (Any?) -> Double? = { number($0).map { $0 * 1_000_000 } }
        return ModelInfo(
            id: id,
            contextLength: (number(m["max_context_length"]) ?? number(m["context_length"])
                ?? number(spec?["availableContextTokens"])).map(Int.init),
            priceIn: perMillion(pricing?["prompt"]) ?? usd("input"),
            priceOut: perMillion(pricing?["completion"]) ?? usd("output"),
            vision: (caps?["vision"] as? Bool) == true || inputs.contains("image") || (specCaps?["supportsVision"] as? Bool) == true,
            reasoning: params.contains("reasoning") || params.contains("include_reasoning")
                || (specCaps?["supportsReasoning"] as? Bool) == true,
            tools: (caps?["function_calling"] as? Bool) == true || params.contains("tools")
                || (specCaps?["supportsFunctionCalling"] as? Bool) == true,
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

    private static func anthropicInfo(_ m: [String: Any]) -> ModelInfo? {
        guard let id = m["id"] as? String else { return nil }
        return ModelInfo(
            id: id,
            contextLength: 200_000,
            vision: id.contains("sonnet") || id.contains("opus") || id.contains("haiku")
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
        if r.jsonMode { body["response_format"] = ["type": "json_object"] }

        var req = try makeRequest(url: join(p.baseURL, "chat/completions"), method: "POST")
        authorize(&req, provider: p, apiKey: key)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await perform(req)

        let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        guard let text = message?["content"] as? String, !text.isEmpty else {
            throw ProviderError.badResponse("empty model reply")
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
        if r.jsonMode { gen["responseMimeType"] = "application/json" }
        if !gen.isEmpty { body["generationConfig"] = gen }

        var req = try makeRequest(url: join(p.baseURL, "models/\(model):generateContent"), method: "POST")
        authorize(&req, provider: p, apiKey: key)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await perform(req)

        let content = (json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any]
        let text = (content?["parts"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw ProviderError.badResponse("empty model reply") }
        let usage = json["usageMetadata"] as? [String: Any]
        return ChatReply(text: text,
                         inputTokens: usage?["promptTokenCount"] as? Int,
                         outputTokens: usage?["candidatesTokenCount"] as? Int)
    }

    // MARK: Anthropic

    private func chatAnthropic(_ p: ProviderConfig, _ model: String, _ key: String, _ r: ChatRequest) async throws -> ChatReply {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": r.prompt]],
            "max_tokens": r.maxTokens ?? 4096
        ]
        var systemText = r.system ?? ""
        if r.jsonMode {
            systemText = (systemText.isEmpty ? "" : systemText + "\n") + "Respond with valid JSON only. Do not surround with markdown codeblocks."
        }
        if !systemText.isEmpty { body["system"] = systemText }
        if let t = r.temperature { body["temperature"] = t }

        var req = try makeRequest(url: join(p.baseURL, "messages"), method: "POST")
        authorize(&req, provider: p, apiKey: key)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await perform(req)

        let content = (json["content"] as? [[String: Any]])?.first
        guard let text = content?["text"] as? String, !text.isEmpty else {
            throw ProviderError.badResponse("empty model reply")
        }
        let usage = json["usage"] as? [String: Any]
        return ChatReply(text: text,
                         inputTokens: usage?["input_tokens"] as? Int,
                         outputTokens: usage?["output_tokens"] as? Int)
    }

    // MARK: wspólne

    private func join(_ base: String, _ path: String) -> String {
        base.hasSuffix("/") ? base + path : base + "/" + path
    }

    private func makeRequest(url: String, method: String) throws -> URLRequest {
        guard let u = URL(string: url) else { throw ProviderError.badResponse("bad URL: \(url)") }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    private func authorize(_ req: inout URLRequest, provider: ProviderConfig, apiKey: String) {
        switch provider.kind {
        case .openai:
            if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        case .gemini:
            if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key") }
        case .anthropic:
            if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .foundation:
            break
        }
    }

    static func parseErrorBody(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errObj = json["error"] as? [String: Any] {
                if let msg = errObj["message"] as? String, !msg.isEmpty {
                    return msg
                }
                if let status = errObj["status"] as? String, !status.isEmpty {
                    return status
                }
            } else if let errMsg = json["error"] as? String, !errMsg.isEmpty {
                return errMsg
            } else if let msg = json["message"] as? String, !msg.isEmpty {
                return msg
            }
        } else if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = arr.first {
            if let errObj = first["error"] as? [String: Any], let msg = errObj["message"] as? String, !msg.isEmpty {
                return msg
            }
        }
        let raw = String(decoding: data.prefix(300), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? "no error body" : raw
    }

    private func perform(_ req: URLRequest) async throws -> [String: Any] {
        let data: Data, http: HTTPURLResponse
        do { (data, http) = try await transport.send(req) }
        catch let e as ProviderError { throw e }
        catch { throw ProviderError.network(error.localizedDescription) }

        guard (200..<300).contains(http.statusCode) else {
            let body = Self.parseErrorBody(data)
            throw ProviderError.http(status: http.statusCode, body: body)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse("response is not a JSON object")
        }
        return json
    }
}
