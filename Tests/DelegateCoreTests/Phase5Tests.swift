import Foundation
import Testing
@testable import DelegateCore

@Suite struct Phase5Tests {
    @Test func renameProviderUpdatesIdAndDefaultEnvKey() {
        var config = Config(providers: [
            ProviderConfig(id: "custom", kind: .openai, baseURL: "https://api.example.com", apiKeyEnv: "CUSTOM_API_KEY")
        ])

        let success = config.renameProvider(from: "custom", to: "groq")
        #expect(success)
        #expect(config.providers.count == 1)
        #expect(config.providers[0].id == "groq")
        #expect(config.providers[0].apiKeyEnv == "GROQ_API_KEY")
    }

    @Test func renameProviderPreservesCustomEnvKey() {
        var config = Config(providers: [
            ProviderConfig(id: "custom", kind: .openai, baseURL: "https://api.example.com", apiKeyEnv: "MY_SPECIAL_TOKEN")
        ])

        let success = config.renameProvider(from: "custom", to: "cerebras")
        #expect(success)
        #expect(config.providers[0].id == "cerebras")
        // Ponieważ apiKeyEnv różnił się od CUSTOM_API_KEY, nie zmieniamy go automatycznie
        #expect(config.providers[0].apiKeyEnv == "MY_SPECIAL_TOKEN")
    }

    @Test func renameProviderValidations() {
        var config = Config(providers: [
            ProviderConfig(id: "alpha", kind: .openai),
            ProviderConfig(id: "beta", kind: .openai)
        ])

        // Pusta nazwa lub same spacje
        let emptyRes = config.renameProvider(from: "alpha", to: "")
        #expect(!emptyRes)
        let spacesRes = config.renameProvider(from: "alpha", to: "   ")
        #expect(!spacesRes)

        // Kolizja z innym dostawcą
        let collisionRes = config.renameProvider(from: "alpha", to: "beta")
        #expect(!collisionRes)

        // Nieistniejący dostawca
        let nonexistentRes = config.renameProvider(from: "nonexistent", to: "gamma")
        #expect(!nonexistentRes)

        // Zmiana na tę samą nazwę
        let sameRes = config.renameProvider(from: "alpha", to: "alpha")
        #expect(sameRes)
        #expect(config.providers[0].id == "alpha")
    }

    @Test func usageLogCostAndAggregation() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let log = UsageLog(url: tmp)
        log.append(UsageEntry(ts: Date(), provider: "mistral", model: "codestral", costUSD: 0.0012, ok: true, ms: 120))
        log.append(UsageEntry(ts: Date(), provider: "openai", model: "gpt-4o", costUSD: 0.0045, ok: true, ms: 250))
        log.append(UsageEntry(ts: Date().addingTimeInterval(-86400 * 5), provider: "old", model: "m", costUSD: 0.05, ok: true, ms: 100))

        let startOfDay = Calendar.current.startOfDay(for: Date())
        let todayEntries = log.entries(since: startOfDay)
        #expect(todayEntries.count == 2)
        let totalCostToday = todayEntries.compactMap(\.costUSD).reduce(0, +)
        #expect(abs(totalCostToday - 0.0057) < 0.00001)
    }
}

@Suite struct PresetTests {
    @Test func addingPresetFillsProviderAndAvoidsCollisions() throws {
        var config = try Config.parse(DefaultConfig.toml)
        let mistral = try #require(ProviderPreset.all.first { $0.id == "mistral" })
        #expect(config.addProvider(from: mistral) == "mistral")
        #expect(config.providers.last?.apiKeyEnv == "MISTRAL_API_KEY")
        #expect(config.providers.last?.models.isEmpty == false)

        // Drugi raz: nowe ID i własna nazwa klucza, żeby nie dzielić wpisu w Keychain.
        #expect(config.addProvider(from: mistral) == "mistral-2")
        #expect(config.providers.last?.apiKeyEnv == "MISTRAL_2_API_KEY")

        let ollama = try #require(ProviderPreset.all.first { $0.id == "ollama" })
        config.addProvider(from: ollama)
        #expect(config.providers.last?.needsKey == false)
    }

    @Test func presetIdsAreUnique() {
        let ids = ProviderPreset.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}

@Suite struct GuideTests {
    private func guide(_ config: Config, ready: Set<String>) -> DelegationGuide {
        DelegationGuide(config: config) { ready.contains($0.id) }
    }

    @Test func instructionsListReadyModelsByTagAndRoutingRules() throws {
        let config = try Config.parse(sampleConfigToml)
        let g = guide(config, ready: ["mistral", "gemini"])
        let text = g.serverInstructions
        #expect(text.contains("- translate: mistral/mistral-small-latest (free), gemini/gemini-flash-latest (free)"))
        #expect(text.contains("Deleguj"))
        #expect(!text.contains("deepseek"))
        #expect(g.tags.first == "general")
        #expect(g.modelParameterDescription.contains("gemini/gemini-pro-latest"))
    }

    @Test func noReadyModelsTellsClaudeNotToDelegate() throws {
        let g = guide(try Config.parse(sampleConfigToml), ready: [])
        #expect(g.serverInstructions.contains("Do not call `delegate`"))
        #expect(g.tags.isEmpty)
    }
}
