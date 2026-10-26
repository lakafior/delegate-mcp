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

    @Test func providerGuidanceAppearsForReadyProvidersOnly() throws {
        var config = try Config.parse(sampleConfigToml)
        config.providers[0].guidance = "Great for translations."
        config.providers[2].guidance = "Never send work data."   // deepseek, niegotowy
        let text = guide(config, ready: ["mistral"]).serverInstructions
        #expect(text.contains("- mistral: Great for translations."))
        #expect(!text.contains("Never send work data."))
        #expect(try Config.parse(try config.serialized()).providers[0].guidance == "Great for translations.")
    }

    @Test func noReadyModelsTellsClaudeNotToDelegate() throws {
        let g = guide(try Config.parse(sampleConfigToml), ready: [])
        #expect(g.serverInstructions.contains("Do not call `delegate`"))
        #expect(g.tags.isEmpty)
    }
}

@Suite struct PriceCatalogTests {
    static let catalogJSON = #"""
    {"sample_spec":{"input_cost_per_token":"x"},
     "mistral/mistral-small-latest":{"input_cost_per_token":1.5e-07,"output_cost_per_token":6e-07,"litellm_provider":"mistral"},
     "claude-haiku-5-5":{"input_cost_per_token":1e-06,"output_cost_per_token":5e-06,"litellm_provider":"anthropic"},
     "gpt-x":{"input_cost_per_token":1e-06,"output_cost_per_token":2e-06,"litellm_provider":"openai"},
     "dall-e":{"output_cost_per_image":0.04}}
    """#

    @Test func lookupUsesProviderPrefixOrOwnedBareId() throws {
        let c = try PriceCatalog.parse(Data(Self.catalogJSON.utf8))
        let mistral = ProviderConfig(id: "m", kind: .openai, baseURL: "https://api.mistral.ai/v1")
        let small = try #require(c.price(for: "mistral-small-latest", provider: mistral))
        #expect(abs(small.input - 0.15) < 1e-9 && abs(small.output - 0.6) < 1e-9)
        let anthropic = ProviderConfig(id: "a", kind: .anthropic, baseURL: "https://api.anthropic.com/v1")
        #expect(c.price(for: "claude-haiku-5-5", provider: anthropic)?.output == 5)
        // Samo ID należące do innego dostawcy nie pasuje.
        #expect(c.price(for: "gpt-x", provider: anthropic) == nil)
        let unknown = ProviderConfig(id: "v", kind: .openai, baseURL: "https://api.venice.ai/api/v1")
        #expect(c.price(for: "mistral-small-latest", provider: unknown) == nil)
    }

    @Test func storeCachesAndFallsBackToStaleCopy() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: cache) }
        let online = MockTransport(["raw.githubusercontent.com": .init(status: 200, body: Self.catalogJSON)])
        #expect(await PriceCatalogStore(cacheURL: cache, transport: online).load() != nil)
        #expect(online.calls.count == 1)

        // Świeża kopia: bez sieci.
        #expect(await PriceCatalogStore(cacheURL: cache, transport: online).load() != nil)
        #expect(online.calls.count == 1)

        // Przeterminowana kopia i awaria sieci: używa starej.
        let offline = MockTransport([:])
        #expect(await PriceCatalogStore(cacheURL: cache, transport: offline, maxAge: 0).load() != nil)
        #expect(offline.calls.count == 1)
    }

    @Test func modelInfosFillMissingPricesFromCatalog() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: cache) }
        let t = MockTransport([
            "api.mistral.ai": .init(status: 200, body: #"{"data":[{"id":"mistral-small-latest"},{"id":"nowy"}]}"#),
            "raw.githubusercontent.com": .init(status: 200, body: Self.catalogJSON),
        ])
        let svc = DelegateService(loadConfig: { Config() }, secrets: FixedSecrets(values: ["K": "k"]), transport: t,
                                  onDevice: FakeOnDevice(),
                                  usage: UsageLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("u-\(UUID()).jsonl")),
                                  priceCatalog: PriceCatalogStore(cacheURL: cache, transport: t))
        let p = ProviderConfig(id: "mistral", kind: .openai, baseURL: "https://api.mistral.ai/v1", apiKeyEnv: "K")
        let infos = try await svc.modelInfos(for: p)
        let small = try #require(infos.first { $0.id == "mistral-small-latest" })
        #expect(small.priceSource == "LiteLLM" && abs((small.priceOut ?? 0) - 0.6) < 1e-9)
        #expect(small.summary.contains("wg LiteLLM"))
        #expect(infos.first { $0.id == "nowy" }?.priceIn == nil)
    }
}

extension PriceCatalogTests {
    @Test func missingModelTriggersRefreshAtMostOncePerInterval() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: cache) }
        // Kopia sprzed wejścia modelu „nowy”.
        try Self.catalogJSON.write(to: cache, atomically: true, encoding: .utf8)
        let newer = #"{"mistral/nowy":{"input_cost_per_token":1e-06,"output_cost_per_token":3e-06,"litellm_provider":"mistral"}}"#
        let t = MockTransport([
            "api.mistral.ai": .init(status: 200, body: #"{"data":[{"id":"nowy"}]}"#),
            "raw.githubusercontent.com": .init(status: 200, body: newer),
        ])
        let p = ProviderConfig(id: "mistral", kind: .openai, baseURL: "https://api.mistral.ai/v1", apiKeyEnv: "K")
        func service(missInterval: TimeInterval) -> DelegateService {
            DelegateService(loadConfig: { Config() }, secrets: FixedSecrets(values: ["K": "k"]), transport: t,
                            onDevice: FakeOnDevice(),
                            usage: UsageLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("u-\(UUID()).jsonl")),
                            priceCatalog: PriceCatalogStore(cacheURL: cache, transport: t, missRefreshInterval: missInterval))
        }
        let catalogCalls = { t.calls.filter { $0.url?.host == "raw.githubusercontent.com" }.count }

        // Kopia świeższa niż interwał: bez pobierania, ceny brak.
        #expect(try await service(missInterval: 3600).modelInfos(for: p).first?.priceIn == nil)
        #expect(catalogCalls() == 0)

        // Kopia starsza niż interwał: jedno pobranie i cena z nowego cennika.
        let info = try #require(try await service(missInterval: 0).modelInfos(for: p).first)
        #expect(info.priceOut == 3 && info.priceSource == "LiteLLM")
        #expect(catalogCalls() == 1)
    }
}

@Suite struct HelperProbeTests {
    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-mcp-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func handshakeReadsInstructionsAndTools() async throws {
        let fake = try script(#"""
        if [ "$1" = "--check-keys" ]; then echo '{"A_KEY":"readable","B_KEY":"needsApproval"}'; exit 0; fi
        read l1; read l2; read l3
        echo '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"delegate","version":"9.9"},"instructions":"use it"}}'
        echo '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"delegate"},{"name":"list_models"}]}}'
        sleep 5
        """#)
        defer { try? FileManager.default.removeItem(at: fake) }
        let probe = HelperProbe(executable: fake)
        let h = try await probe.handshake(timeout: 3)
        #expect(h.serverVersion == "9.9" && h.hasInstructions && h.tools == ["delegate", "list_models"])
        #expect(try await probe.keyAccess() == ["A_KEY": .readable, "B_KEY": .needsApproval])
    }

    @Test func handshakeTimesOutOnSilentServer() async throws {
        let fake = try script("sleep 30\n")
        defer { try? FileManager.default.removeItem(at: fake) }
        let started = Date()
        await #expect(throws: HelperProbe.ProbeError.self) { try await HelperProbe(executable: fake).handshake(timeout: 1) }
        #expect(Date().timeIntervalSince(started) < 5)
    }
}

@Suite struct ConfigMergeTests {
    private func provider(_ id: String, tags: [String] = []) -> ProviderConfig {
        ProviderConfig(id: id, kind: .openai, baseURL: "https://\(id)", models: [ModelConfig(id: "m", tags: tags)])
    }

    @Test func keepsExternalEditsAndGuiEdits() {
        let base = Config(routingGuidance: "stare", providers: [provider("a"), provider("b")])
        var mine = base
        mine.providers[0].enabled = false                       // GUI: wyłącza a
        var theirs = base
        theirs.routingGuidance = "nowe"                          // z zewnątrz: zasady
        theirs.providers[1].models[0].tags = ["code"]            // z zewnątrz: tagi b (update_models)
        let merged = Config.merge(base: base, mine: mine, theirs: theirs)
        #expect(merged.routingGuidance == "nowe")
        #expect(merged.providers[0].enabled == false)
        #expect(merged.providers[1].models[0].tags == ["code"])
    }

    @Test func mergesAddRemoveAndOrder() {
        let base = Config(providers: [provider("a"), provider("b"), provider("c")])
        var mine = base
        mine.providers.removeAll { $0.id == "c" }               // GUI: usuwa c
        mine.providers.reverse()                                 // GUI: kolejność b, a
        var theirs = base
        theirs.providers.append(provider("d"))                   // z zewnątrz: nowy d
        let merged = Config.merge(base: base, mine: mine, theirs: theirs)
        #expect(merged.providers.map(\.id) == ["b", "a", "d"])
    }

    @Test func guiWinsWhenBothChangedSameProvider() {
        let base = Config(providers: [provider("a")])
        var mine = base; mine.providers[0].note = "gui"
        var theirs = base; theirs.providers[0].note = "plik"
        #expect(Config.merge(base: base, mine: mine, theirs: theirs).providers[0].note == "gui")
    }
}

@Suite struct ConfigWriterTests {
    @Test func roundTripsSampleAndKeepsUnicode() throws {
        var c = try Config.parse(sampleConfigToml)
        c.providers[0].guidance = "Dobry do tłumaczeń \"cudzysłów\" i \\ backslash"
        c.providers[0].note = "linia 1\nlinia 2 \"\"\" potrójny"
        c.providers[1].enabled = false
        c.providers[1].timeoutSeconds = 45.5
        c.providers[0].models[0].priceIn = 0.0000001
        c.providers[0].models[0].priceOut = 3
        let text = try c.serialized()
        #expect(text.contains("Dobry do tłumaczeń"))        // bez \u0142
        #expect(!text.contains("\\u0"))
        #expect(text.contains("price_out = 3\n"))
        #expect(!text.contains("e-07"))
        #expect(text.contains("[[provider]]\nid = \"mistral\"\ntype = \"openai\""))
        #expect(try Config.parse(text) == c)
    }

    @Test func omitsDefaults() throws {
        let c = Config(providers: [ProviderConfig(id: "x", kind: .foundation)])
        let text = try c.serialized()
        #expect(!text.contains("enabled"))
        #expect(!text.contains("base_url"))
        #expect(try Config.parse(text) == c)
    }
}

@Suite struct RoutingPolicyTests {
    private let keys = ["MISTRAL_API_KEY": "m", "GEMINI_API_KEY": "g", "DEEPSEEK_API_KEY": "d", "OPENROUTER_API_KEY": "o"]

    @Test func regionsAreInferredFromAddress() throws {
        let c = try Config.parse(sampleConfigToml)
        let regions = Dictionary(uniqueKeysWithValues: c.providers.map { ($0.id, $0.effectivePrivacy) })
        #expect(regions == ["mistral": .eu, "gemini": .us, "deepseek": .cn, "openrouter": .us, "apple": .local])
        #expect(PrivacyRegion.inferred(for: ProviderConfig(id: "o", kind: .openai, baseURL: "http://localhost:11434/v1")) == .local)
        #expect(PrivacyRegion.inferred(for: ProviderConfig(id: "x", kind: .openai, baseURL: "https://api.nowy.dev/v1")) == .other)
    }

    @Test func sensitivityIsEnforced() throws {
        let (svc, _) = try makeService(MockTransport([:]), keys: keys, onDevice: FakeOnDevice(availability: .available))
        let cfg = try Config.parse(sampleConfigToml)
        let personal = svc.routingPlan(for: .init(prompt: "x", sensitivity: .personal), config: cfg)
        #expect(!personal.candidates.contains { $0.provider.id == "deepseek" })
        #expect(personal.excluded.contains { $0.ref == "deepseek" && $0.reason.contains("cn") })
        let priv = svc.routingPlan(for: .init(prompt: "x", sensitivity: .private), config: cfg)
        #expect(Set(priv.candidates.map(\.provider.id)) == ["apple"])
        let pub = svc.routingPlan(for: .init(prompt: "x"), config: cfg)
        #expect(pub.candidates.contains { $0.provider.id == "deepseek" })
    }

    @Test func privateTaskWithoutLocalModelFailsWithReasons() async throws {
        let (svc, _) = try makeService(MockTransport([:]), keys: keys)   // model Apple niedostępny
        let error = await #expect(throws: DelegateError.self) {
            try await svc.delegate(.init(prompt: "x", sensitivity: .private))
        }
        #expect(error?.description.contains("Pominięte") == true)
    }

    @Test func spentBudgetSkipsPaidModels() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID()).jsonl")
        UsageLog(url: log).append(UsageEntry(provider: "deepseek", model: "deepseek-chat", costUSD: 0.6, ok: true, ms: 1))
        var cfg = try Config.parse(sampleConfigToml)
        cfg.dailyBudgetUSD = 0.5
        let svc = DelegateService(loadConfig: { Config() }, secrets: FixedSecrets(values: keys), transport: MockTransport([:]),
                                  onDevice: FakeOnDevice(), usage: UsageLog(url: log))
        let plan = svc.routingPlan(for: .init(prompt: "x"), config: cfg)
        #expect(plan.spentToday == 0.6)
        // deepseek („cheap”), gemini-pro („paid”) i openrouter („varies”) odpadają; darmowe zostają.
        #expect(plan.candidates.allSatisfy { $0.model.cost == "free" })
        #expect(plan.excluded.contains { $0.ref == "deepseek/deepseek-chat" && $0.reason.contains("budżet") })
        cfg.dailyBudgetUSD = 5
        #expect(svc.routingPlan(for: .init(prompt: "x"), config: cfg).candidates.contains { $0.provider.id == "deepseek" })
    }

    @Test func newFieldsRoundTripAndTolerateUnknownValues() throws {
        var c = try Config.parse(sampleConfigToml)
        c.delegationMode = .aggressive
        c.personalRegions = [.local, .eu]
        c.dailyBudgetUSD = 2.5
        c.providers[3].privacy = .eu
        #expect(try Config.parse(try c.serialized()) == c)
        let odd = try Config.parse("delegation_mode = 'wild'\n[[provider]]\nid='x'\ntype='openai'\nprivacy='mars'")
        #expect(odd.delegationMode == .balanced && odd.providers[0].privacy == nil)
        #expect(odd.personalRegions == Config.defaultPersonalRegions)
    }

    @Test func instructionsFollowModeAndSensitivity() throws {
        var c = try Config.parse(sampleConfigToml)
        c.delegationMode = .aggressive
        c.dailyBudgetUSD = 1
        let g = DelegationGuide(config: c) { ["mistral", "apple"].contains($0.id) }
        let text = g.serverInstructions
        #expect(text.contains("Delegate by default"))
        #expect(text.contains("~50"))
        #expect(text.contains("only providers in these regions: local, eu, us"))
        #expect(text.contains("only local models (apple)"))
        #expect(text.contains("daily budget of $1.00"))
        let noLocal = DelegationGuide(config: c) { $0.id == "mistral" }.serverInstructions
        #expect(noLocal.contains("No local model is ready"))
    }
}
