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
