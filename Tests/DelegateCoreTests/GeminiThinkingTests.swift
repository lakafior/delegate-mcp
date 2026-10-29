import Foundation
import Testing
@testable import DelegateCore

/// R5: Gemini 3+ domyślnie długo myśli; dla zadań delegowanych wysyłamy niski poziom myślenia.
@Suite struct GeminiThinkingTests {
    /// Odpowiedzi po kolei (ostatnia się powtarza), żeby sprawdzić ponowienie.
    final class SequenceTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [MockTransport.Reply]
        private var recorded: [URLRequest] = []
        var bodies: [[String: Any]] {
            lock.withLock { recorded.compactMap { $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } } }
        }

        init(_ replies: [MockTransport.Reply]) { self.replies = replies }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let reply = lock.withLock {
                recorded.append(request)
                return replies.count > 1 ? replies.removeFirst() : replies[0]
            }
            return (Data(reply.body.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private let gemini = ProviderConfig(id: "gemini", kind: .gemini, baseURL: "https://generativelanguage.googleapis.com/v1beta")
    private let thinkingBody = #"{"candidates":[{"content":{"parts":[{"text":"hej"}]}}],"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":2,"thoughtsTokenCount":40}}"#

    private func level(_ body: [String: Any]?) -> String? {
        ((body?["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String
    }

    @Test func defaultLevelDependsOnModelFamily() {
        #expect(ProviderClient.geminiThinking(model: "gemini-flash-latest", configured: nil) == "low")
        #expect(ProviderClient.geminiThinking(model: "gemini-3.8-flash", configured: nil) == "low")
        #expect(ProviderClient.geminiThinking(model: "gemini-2.5-flash", configured: nil) == nil)
        #expect(ProviderClient.geminiThinking(model: "gemma-4-31b-it", configured: nil) == nil)
        #expect(ProviderClient.geminiThinking(model: "gemini-flash-lite-latest", configured: nil) == nil)   // domyślnie minimal
        #expect(ProviderClient.geminiThinking(model: "gemini-flash-latest", configured: "high") == "high")
        #expect(ProviderClient.geminiThinking(model: "gemini-flash-latest", configured: "default") == nil)
    }

    @Test func sendsLowThinkingAndCountsThoughtsAsOutput() async throws {
        let t = SequenceTransport([.init(status: 200, body: thinkingBody)])
        let reply = try await ProviderClient(transport: t, timeout: 10)
            .chat(provider: gemini, model: "gemini-flash-latest", apiKey: "k", request: ChatRequest(prompt: "x"))
        #expect(level(t.bodies.first) == "low")
        #expect(reply.outputTokens == 42)
    }

    @Test func retriesWithTheModelsDefaultWhenTheLevelIsRejected() async throws {
        let t = SequenceTransport([
            .init(status: 400, body: #"{"error":{"message":"Thinking level minimal is not supported for this model."}}"#),
            .init(status: 200, body: geminiBody),
        ])
        let reply = try await ProviderClient(transport: t, timeout: 10)
            .chat(provider: gemini, model: "gemini-flash-latest", apiKey: "k", request: ChatRequest(prompt: "x", thinking: "minimal"))
        #expect(reply.text == "hej")
        #expect(t.bodies.count == 2)
        #expect(level(t.bodies[0]) == "minimal")
        #expect(level(t.bodies[1]) == nil)
    }

    @Test func modelSettingReachesTheRequestAndRoundTrips() async throws {
        var p = gemini
        p.apiKeyEnv = "GEMINI_API_KEY"
        p.models = [ModelConfig(id: "gemini-pro-latest", thinking: "high")]
        let config = Config(providers: [p])
        #expect(try Config.parse(try config.serialized()) == config)
        #expect(try config.serialized().contains("thinking = \"high\""))

        let t = SequenceTransport([.init(status: 200, body: geminiBody)])
        let log = UsageLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID()).jsonl"))
        let svc = DelegateService(loadConfig: { config }, secrets: FixedSecrets(values: ["GEMINI_API_KEY": "g"]), transport: t,
                                  onDevice: FakeOnDevice(), usage: log)
        _ = try await svc.delegate(.init(prompt: "x"))
        #expect(level(t.bodies.first) == "high")
    }
}
