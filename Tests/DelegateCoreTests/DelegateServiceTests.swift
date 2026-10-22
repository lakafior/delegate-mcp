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

struct FakeOnDevice: OnDeviceModel {
    var availability: OnDeviceAvailability = .unavailable("test")
    func respond(_ request: ChatRequest) async throws -> ChatReply {
        ChatReply(text: "lokalnie: \(request.prompt)", inputTokens: nil, outputTokens: nil)
    }
}

func makeService(_ transport: MockTransport, keys: [String: String], config: Config? = nil,
                 onDevice: FakeOnDevice = FakeOnDevice()) throws -> (DelegateService, URL) {
    let cfg = try config ?? Config.parse(DefaultConfig.toml)
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).jsonl")
    return (DelegateService(loadConfig: { cfg }, secrets: FixedSecrets(values: keys), transport: transport,
                            onDevice: onDevice, usage: UsageLog(url: log)), log)
}

@Suite struct ConfigTests {
    @Test func defaultConfigParses() throws {
        let c = try Config.parse(DefaultConfig.toml)
        #expect(c.providers.map(\.id) == ["mistral", "gemini", "deepseek", "openrouter", "apple"])
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
        #expect(with.count == 4)  // apple niedostępny w teście
        let only = svc.candidates(for: .init(prompt: "x", model: "deepseek-chat", allowFallback: false), config: cfg)
        #expect(only.map(\.ref) == ["deepseek/deepseek-chat"])
    }

    @Test func onDeviceModelNeedsNoKeyAndIsLastResort() async throws {
        let t = MockTransport([:])
        let (svc, _) = try makeService(t, keys: [:], onDevice: FakeOnDevice(availability: .available))
        let out = try await svc.delegate(.init(prompt: "cześć", task: "private"))
        #expect(out.contains("model: apple/on-device"))
        #expect(out.hasSuffix("lokalnie: cześć"))
        #expect(t.calls.isEmpty)
    }

    @Test func unavailableOnDeviceIsSkippedAndExplained() throws {
        let (svc, _) = try makeService(MockTransport([:]), keys: [:])
        let out = try svc.listModels()
        #expect(out.contains("**apple** (foundation) — niedostępny: test"))
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
        #expect(out.contains("**mistral** (openai) — gotowy"))
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
        #expect(out.contains("- a"))
        #expect(out.contains("- b"))
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

@Suite struct ClaudeIntegrationTests {
    @Test func desktopConfigMergePreservesOtherKeys() throws {
        let original = Data(#"{"theme":"dark","mcpServers":{"other":{"command":"/x"}}}"#.utf8)
        let added = try ClaudeIntegration.updatingDesktopConfig(original, command: "/app/delegate-mcp")
        #expect(ClaudeIntegration.registeredCommand(in: added) == "/app/delegate-mcp")
        let obj = try JSONSerialization.jsonObject(with: added) as! [String: Any]
        #expect(obj["theme"] as? String == "dark")
        #expect((obj["mcpServers"] as! [String: Any])["other"] != nil)

        let removed = try ClaudeIntegration.updatingDesktopConfig(added, command: nil)
        #expect(ClaudeIntegration.registeredCommand(in: removed) == nil)
        #expect(String(decoding: removed, as: UTF8.self).contains("other"))
    }

    @Test func createsConfigFromNothing() throws {
        let data = try ClaudeIntegration.updatingDesktopConfig(nil, command: "/p")
        #expect(ClaudeIntegration.registeredCommand(in: data) == "/p")
    }

    @Test func instructionsAreIdempotentAndRemovable() {
        let once = ClaudeIntegration.addingInstructions(to: "# Moje\n")
        #expect(ClaudeIntegration.hasInstructions(once))
        #expect(ClaudeIntegration.addingInstructions(to: once) == once)
        #expect(ClaudeIntegration.removingInstructions(from: once) == "# Moje\n")
    }

    @Test func statusRule() {
        let p = ProviderConfig(id: "x", kind: .openai, baseURL: "u", apiKeyEnv: "K")
        #expect(ProviderStatus.evaluate(p, hasKey: false, onDevice: .available) == .missingKey("K"))
        var off = p; off.enabled = false
        #expect(ProviderStatus.evaluate(off, hasKey: true, onDevice: .available) == .disabled)
        let a = ProviderConfig(id: "a", kind: .foundation)
        #expect(ProviderStatus.evaluate(a, hasKey: false, onDevice: .available) == .ready)
    }
}


@Suite struct CatalogTests {
    @Test func tagSuggestionsFromIdsAndMetadata() {
        #expect(ModelInfo(id: "codestral-latest").suggestedTags == ["code"])
        #expect(ModelInfo(id: "mistral-small-latest").suggestedTags == ["general", "translate", "summarize", "fast"])
        #expect(ModelInfo(id: "deepseek-reasoner").suggestedTags == ["reasoning"])
        #expect(ModelInfo(id: "gemini-pro-latest", contextLength: 1_000_000).suggestedTags == ["reasoning", "long-context"])
        #expect(ModelInfo(id: "mistral-embed").suggestedTags.isEmpty)
        #expect(ModelInfo(id: "x", vision: true).suggestedTags.contains("vision"))
    }

    @Test func openRouterMetadataGivesPricesPerMillion() async throws {
        let body = #"{"data":[{"id":"a/b","context_length":128000,"pricing":{"prompt":"0.00000015","completion":"0.0000006"},"architecture":{"input_modalities":["text","image"]},"supported_parameters":["tools","reasoning"]},{"id":"c/free:free","pricing":{"prompt":"0","completion":"0"}}]}"#
        let t = MockTransport(["openrouter.ai": .init(status: 200, body: body)])
        let (svc, _) = try makeService(t, keys: ["OPENROUTER_API_KEY": "k"])
        let p = try Config.parse(DefaultConfig.toml).providers.first { $0.id == "openrouter" }!
        let infos = try await svc.modelInfos(for: p)
        let a = try #require(infos.first { $0.id == "a/b" })
        #expect(abs((a.priceIn ?? 0) - 0.15) < 1e-9)
        #expect(abs((a.priceOut ?? 0) - 0.6) < 1e-9)
        #expect(a.vision && a.reasoning && a.tools)
        #expect(a.contextLength == 128000)
        #expect(infos.first { $0.id == "c/free:free" }?.suggestedCategory == "free")
    }

    @Test func mistralCapabilitiesMarkNonChat() async throws {
        let body = #"{"data":[{"id":"mistral-embed","capabilities":{"completion_chat":false},"max_context_length":8000},{"id":"pixtral-x","capabilities":{"completion_chat":true,"vision":true}}]}"#
        let t = MockTransport(["api.mistral.ai": .init(status: 200, body: body)])
        let (svc, _) = try makeService(t, keys: ["MISTRAL_API_KEY": "k"])
        let p = try Config.parse(DefaultConfig.toml).providers[0]
        let infos = try await svc.modelInfos(for: p)
        #expect(infos.first { $0.id == "mistral-embed" }?.isChat == false)
        #expect(infos.first { $0.id == "pixtral-x" }?.suggestedTags.contains("vision") == true)
    }

    @Test func costLabelAndTomlRoundTripWithPrices() throws {
        var c = try Config.parse(DefaultConfig.toml)
        c.providers[0].models[0].cost = nil
        c.providers[0].models[0].priceIn = 0.1
        c.providers[0].models[0].priceOut = 3
        #expect(c.providers[0].models[0].costLabel == "$0.1 in / $3 out za 1M tok.")
        #expect(try Config.parse(try c.serialized()) == c)
        let hand = try Config.parse("[[provider]]\nid='x'\ntype='openai'\n[[provider.model]]\nid='m'\nprice_in = 1\nprice_out = 2")
        #expect(hand.providers[0].models[0].priceIn == 1)
    }

    @Test func updateModelsUpsertsAndKeepsCostModesExclusive() throws {
        let box = ConfigBox(try Config.parse(DefaultConfig.toml))
        let svc = DelegateService(loadConfig: { box.value }, secrets: FixedSecrets(values: [:]),
                                  transport: MockTransport([:]), onDevice: FakeOnDevice(),
                                  saveConfig: { box.value = $0 },
                                  usage: UsageLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("u-\(UUID()).jsonl")))
        let msg = try svc.updateModels(provider: "mistral", updates: [
            ModelUpdate(id: "mistral-small-latest", tags: [" Code ", "code", "Fast"], priceIn: 0.1, priceOut: 0.3),
            ModelUpdate(id: "new-model", cost: "cheap"),
        ])
        #expect(msg.contains("zaktualizowano 1, dodano 1"))
        let models = box.value.providers[0].models
        let small = try #require(models.first { $0.id == "mistral-small-latest" })
        #expect(small.tags == ["code", "fast"])
        #expect(small.cost == nil && small.priceIn == 0.1)
        #expect(models.first { $0.id == "new-model" }?.cost == "cheap")
        #expect(throws: DelegateError.self) { try svc.updateModels(provider: "nope", updates: []) }
    }
}

final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Config
    init(_ c: Config) { stored = c }
    var value: Config {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
