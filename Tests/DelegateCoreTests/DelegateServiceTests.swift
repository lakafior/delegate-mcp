import Foundation
import Testing
@testable import DelegateCore

/// Transport z gotowymi odpowiedziami wg hosta; zapamiętuje wywołania.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Reply { var status: Int; var body: String }
    private let lock = NSLock()
    private let replies: [String: Reply]
    private var recorded: [URLRequest] = []
    var calls: [URLRequest] { lock.withLock { recorded } }

    init(_ replies: [String: Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        let host = request.url?.host ?? ""
        let reply = replies[host] ?? Reply(status: 404, body: "{}")
        let http = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        return (Data(reply.body.utf8), http)
    }
}

struct FixedSecrets: SecretStore {
    var values: [String: String]
    func secret(for name: String) -> String? { values[name] }
}

let openAIBody = #"{"choices":[{"message":{"content":"cześć"}}],"usage":{"prompt_tokens":10,"completion_tokens":3}}"#
let geminiBody = #"{"candidates":[{"content":{"parts":[{"text":"hej"}]}}],"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":2}}"#

func makeService(_ transport: MockTransport, keys: [String: String], config: Config? = nil) throws -> (DelegateService, URL) {
    let cfg = try config ?? Config.parse(DefaultConfig.toml)
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).jsonl")
    return (DelegateService(loadConfig: { cfg }, secrets: FixedSecrets(values: keys), transport: transport, usage: UsageLog(url: log)), log)
}

@Suite struct ConfigTests {
    @Test func defaultConfigParses() throws {
        let c = try Config.parse(DefaultConfig.toml)
        #expect(c.providers.map(\.id) == ["mistral", "gemini", "deepseek", "openrouter"])
        #expect(c.providers[1].kind == .gemini)
        #expect(c.providers[0].models.first?.tags.contains("translate") == true)
        #expect(c.routingGuidance.contains("Deleguj"))
    }

    @Test func roundTrip() throws {
        let c = try Config.parse(DefaultConfig.toml)
        #expect(try Config.parse(try c.serialized()) == c)
    }

    @Test func dotEnvParsing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("env-\(UUID().uuidString)")
        try "# komentarz\nA=1\nB = \"dwa\"\nC='trzy'\n".write(to: url, atomically: true, encoding: .utf8)
        let s = EnvSecretStore(environment: [:], dotEnv: url)
        #expect(s.secret(for: "A") == "1")
        #expect(s.secret(for: "B") == "dwa")
        #expect(s.secret(for: "C") == "trzy")
        #expect(s.secret(for: "D") == nil)
    }
}

@Suite struct RoutingTests {
    @Test func skipsProvidersWithoutKeyAndUsesPriority() async throws {
        let t = MockTransport(["api.deepseek.com": .init(status: 200, body: openAIBody)])
        let (svc, _) = try makeService(t, keys: ["DEEPSEEK_API_KEY": "k"])
        let out = try await svc.delegate(.init(prompt: "x"))
        #expect(out.contains("model: deepseek/deepseek-chat"))
        #expect(out.hasSuffix("cześć"))
        #expect(out.contains("10 in / 3 out"))
    }

    @Test func fallsBackOnRateLimitAndReportsIt() async throws {
        let t = MockTransport([
            "api.mistral.ai": .init(status: 429, body: #"{"error":"rate limit"}"#),
            "generativelanguage.googleapis.com": .init(status: 200, body: geminiBody),
        ])
        let (svc, log) = try makeService(t, keys: ["MISTRAL_API_KEY": "m", "GEMINI_API_KEY": "g"])
        let out = try await svc.delegate(.init(prompt: "x", task: "summarize"))
        #expect(out.contains("model: gemini/gemini-flash-latest"))
        #expect(out.contains("mistral/mistral-small-latest → HTTP 429"))
        #expect(out.hasSuffix("hej"))
        #expect(UsageLog(url: log).entries().map(\.ok) == [false, true])
        // klucz Gemini idzie w nagłówku, nie w URL
        let gemini = t.calls.last!
        #expect(gemini.value(forHTTPHeaderField: "x-goog-api-key") == "g")
        #expect(gemini.url?.query == nil)
    }

    @Test func taskTagReordersCandidates() throws {
        let t = MockTransport([:])
        let (svc, _) = try makeService(t, keys: ["MISTRAL_API_KEY": "m", "DEEPSEEK_API_KEY": "d"])
        let cfg = try Config.parse(DefaultConfig.toml)
        let list = svc.candidates(for: .init(prompt: "x", task: "reasoning"), config: cfg)
        #expect(list.first?.ref == "deepseek/deepseek-reasoner")
    }

    @Test func explicitModelFirstAndNoFallbackWhenDisabled() throws {
        let t = MockTransport([:])
        let (svc, _) = try makeService(t, keys: ["MISTRAL_API_KEY": "m", "DEEPSEEK_API_KEY": "d"])
        let cfg = try Config.parse(DefaultConfig.toml)
        let with = svc.candidates(for: .init(prompt: "x", model: "deepseek/deepseek-chat"), config: cfg)
        #expect(with.first?.ref == "deepseek/deepseek-chat")
        #expect(with.count == 4)
        let only = svc.candidates(for: .init(prompt: "x", model: "deepseek-chat", allowFallback: false), config: cfg)
        #expect(only.map(\.ref) == ["deepseek/deepseek-chat"])
    }

    @Test func allFailuresThrowWithDetails() async throws {
        let t = MockTransport(["api.mistral.ai": .init(status: 402, body: "no credits")])
        let (svc, _) = try makeService(t, keys: ["MISTRAL_API_KEY": "m"])
        await #expect(throws: DelegateError.self) { try await svc.delegate(.init(prompt: "x")) }
    }
}

@Suite struct ToolOutputTests {
    @Test func listModelsShowsKeyStatusButNeverKeys() throws {
        let (svc, _) = try makeService(MockTransport([:]), keys: ["MISTRAL_API_KEY": "sekret-123"])
        let out = try svc.listModels()
        #expect(out.contains("**mistral** (openai) — klucz OK"))
        #expect(out.contains("brak klucza (GEMINI_API_KEY)"))
        #expect(!out.contains("sekret-123"))
        #expect(out.contains("Zasady routingu"))
    }

    @Test func remoteModelsParsesBothFormats() async throws {
        let t = MockTransport([
            "api.mistral.ai": .init(status: 200, body: #"{"data":[{"id":"b"},{"id":"a"}]}"#),
            "generativelanguage.googleapis.com": .init(status: 200, body: #"{"models":[{"name":"models/gemini-x","supportedGenerationMethods":["generateContent"]},{"name":"models/emb","supportedGenerationMethods":["embedContent"]}]}"#),
        ])
        let (svc, _) = try makeService(t, keys: ["MISTRAL_API_KEY": "m", "GEMINI_API_KEY": "g"])
        let out = try await svc.listRemoteModels(providerID: nil)
        #expect(out.contains("- a\n- b"))
        #expect(out.contains("- gemini-x"))
        #expect(!out.contains("emb"))
    }

    @Test func usageSummaryAggregates() throws {
        let (svc, log) = try makeService(MockTransport([:]), keys: [:])
        let l = UsageLog(url: log)
        l.append(.init(provider: "p", model: "m", inputTokens: 5, outputTokens: 7, ok: true, ms: 10))
        l.append(.init(provider: "p", model: "m", ok: false, error: "x", ms: 1))
        let out = svc.usageSummary()
        #expect(out.contains("`p/m`: 2 wywołań (błędy: 1), tokeny: 5 in / 7 out"))
    }
}
