import Foundation
import Testing
@testable import DelegateCore

/// R3: każda odmowa routingu mówi Claude'owi, co zrobić dalej, zamiast samego „nie”.
@Suite struct RefusalAdviceTests {
    private func provider(_ id: String, _ url: String, key: String = "", models: [ModelConfig]) -> ProviderConfig {
        ProviderConfig(id: id, kind: .openai, baseURL: url, apiKeyEnv: key, models: models)
    }

    private func refusal(_ request: DelegateRequest, config: Config, keys: [String: String] = [:],
                         transport: MockTransport = MockTransport([:]), usage: UsageLog? = nil,
                         prepare: (DelegateService) -> Void = { _ in }) async -> String {
        let log = usage ?? UsageLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID()).jsonl"))
        let svc = DelegateService(loadConfig: { config }, secrets: FixedSecrets(values: keys), transport: transport,
                                  onDevice: FakeOnDevice(), usage: log)
        prepare(svc)
        let error = await #expect(throws: DelegateError.self) { try await svc.delegate(request) }
        let text = error?.description ?? ""
        #expect(text.contains("do the task yourself"))
        return text
    }

    @Test func privateTaskWithoutLocalModel() async throws {
        let text = await refusal(.init(prompt: "x", sensitivity: .private), config: try Config.parse(sampleConfigToml),
                                 keys: ["MISTRAL_API_KEY": "m"])
        #expect(text.contains("What to do:"))
        #expect(text.contains("Private tasks run only on local models"))
        #expect(text.contains("Lower `sensitivity` only if"))
    }

    @Test func personalTaskWithOnlyChineseProvider() async {
        let cfg = Config(providers: [provider("deepseek", "https://api.deepseek.com/v1", key: "DEEPSEEK_API_KEY",
                                              models: [ModelConfig(id: "deepseek-chat")])])
        let text = await refusal(.init(prompt: "x", sensitivity: .personal), config: cfg, keys: ["DEEPSEEK_API_KEY": "d"])
        #expect(text.contains("Personal data goes only to regions eu, local, us"))
        #expect(!text.contains("Private tasks"))
    }

    @Test func spentBudget() async {
        let log = UsageLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID()).jsonl"))
        log.append(UsageEntry(provider: "x", model: "y", costUSD: 1, ok: true, ms: 1))
        var cfg = Config(providers: [provider("gateway", "http://localhost:20128/v1", models: [ModelConfig(id: "auto")])])
        cfg.dailyBudgetUSD = 0.5
        let text = await refusal(.init(prompt: "x"), config: cfg, usage: log)
        #expect(text.contains("daily budget used up"))
        #expect(text.contains("the user can raise daily_budget_usd"))
    }

    @Test func pausedModels() async {
        let cfg = Config(providers: [provider("mistral", "https://api.mistral.ai/v1", key: "MISTRAL_API_KEY",
                                              models: [ModelConfig(id: "mistral-small-latest")])])
        let text = await refusal(.init(prompt: "x"), config: cfg, keys: ["MISTRAL_API_KEY": "m"]) { svc in
            svc.cooldowns.set("mistral/mistral-small-latest", ModelCooldown(until: Date().addingTimeInterval(300), reason: "overloaded"))
        }
        #expect(text.contains("Some models are paused"))
        #expect(!text.contains("No provider is ready"))
    }

    @Test func pinnedModelGetsOnlyItsOwnReasons() async {
        let log = UsageLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID()).jsonl"))
        log.append(UsageEntry(provider: "x", model: "y", costUSD: 1, ok: true, ms: 1))
        var cfg = Config(providers: [provider("mistral", "https://api.mistral.ai/v1", key: "MISTRAL_API_KEY",
                                              models: [ModelConfig(id: "mistral-small-latest", cost: "free"),
                                                       ModelConfig(id: "mistral-large-latest", cost: "paid")])])
        cfg.dailyBudgetUSD = 0.5
        let text = await refusal(.init(prompt: "x", model: "mistral/mistral-small-latest", allowFallback: false),
                                 config: cfg, keys: ["MISTRAL_API_KEY": "m"], usage: log) { svc in
            svc.cooldowns.set("mistral/mistral-small-latest", ModelCooldown(until: Date().addingTimeInterval(300), reason: "overloaded"))
        }
        #expect(text.contains("drop fallback = false"))
        #expect(text.contains("Some models are paused"))
        #expect(!text.contains("daily_budget_usd"))   // budżet zatrzymał inny model
    }

    @Test func unknownPinnedModel() async throws {
        let text = await refusal(.init(prompt: "x", model: "mistral/nope", allowFallback: false),
                                 config: try Config.parse(sampleConfigToml), keys: ["MISTRAL_API_KEY": "m"])
        #expect(text.contains("\"mistral/nope\" is not in the catalog"))
        #expect(!text.contains("No provider is ready"))
    }

    @Test func noProviderReady() async throws {
        let text = await refusal(.init(prompt: "x"), config: try Config.parse(sampleConfigToml))
        #expect(text.contains("No provider is ready"))
    }

    @Test func allAttemptsFailed() async {
        let cfg = Config(providers: [provider("mistral", "https://api.mistral.ai/v1", key: "MISTRAL_API_KEY",
                                              models: [ModelConfig(id: "mistral-small-latest")])])
        let t = MockTransport(["api.mistral.ai": .init(status: 500, body: #"{"error":{"message":"boom"}}"#)])
        let text = await refusal(.init(prompt: "x"), config: cfg, keys: ["MISTRAL_API_KEY": "m"], transport: t)
        #expect(text.contains("All attempts failed"))
        #expect(text.contains("What to do: retry later"))
    }
}
