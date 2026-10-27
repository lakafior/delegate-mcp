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
        // Jedna linia na dostawcę; translate/summarize wynikają z general, wspólny koszt raz przy dostawcy.
        #expect(text.contains("- mistral · eu · free: mistral-small-latest (general), codestral-latest (code)"))
        #expect(text.contains("- gemini · us: gemini-flash-latest (free, general, long-context), gemini-pro-latest (paid, reasoning, code)"))
        #expect(text.contains("User's rules: Deleguj"))
        #expect(!text.contains("deepseek"))
        #expect(text.contains("`files`"))
        #expect(text.contains("`output_file`"))
        #expect(text.contains("`background: true`"))
        #expect(g.tags.first == "general")
    }

    @Test func providerGuidanceAppearsForReadyProvidersOnly() throws {
        var config = try Config.parse(sampleConfigToml)
        config.providers[0].guidance = "Great for translations."
        config.providers[2].guidance = "Never send work data."   // deepseek, niegotowy
        let text = guide(config, ready: ["mistral"]).serverInstructions
        #expect(text.contains("codestral-latest (code). Note: Great for translations."))
        #expect(!text.contains("Never send work data."))
        #expect(try Config.parse(try config.serialized()).providers[0].guidance == "Great for translations.")
    }

    @Test func noReadyModelsTellsClaudeNotToDelegate() throws {
        let g = guide(try Config.parse(sampleConfigToml), ready: [])
        #expect(g.serverInstructions.contains("Don't call `delegate`"))
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
        #expect(small.summary.contains("via LiteLLM"))
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
        #expect(error?.description.contains("Skipped") == true)
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
        #expect(plan.excluded.contains { $0.ref == "deepseek/deepseek-chat" && $0.reason.contains("budget") })
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
        #expect(text.contains("`personal` = personal or work data, regions local, eu, us"))
        #expect(text.contains("local models only (apple)"))
        #expect(text.contains("after $1.00"))
        let noLocal = DelegationGuide(config: c) { $0.id == "mistral" }.serverInstructions
        #expect(noLocal.contains("no local model is ready"))
    }
}

@Suite struct FilesAndFallbackTests {
    private func temp(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("files-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func filesAreAppendedByNameAndValidated() throws {
        let log = try temp("build.log", Data("linia błędu\n".utf8))
        let composed = try FileAttachments.compose(prompt: "Streść log.", paths: [log.path])
        #expect(composed.prompt.contains("--- File: build.log ---\nlinia błędu"))
        #expect(!composed.prompt.contains(log.deletingLastPathComponent().path))   // bez pełnej ścieżki
        #expect(composed.count == 1)

        #expect(throws: DelegateError.self) { try FileAttachments.compose(prompt: "", paths: ["relative.txt"]) }
        #expect(throws: DelegateError.self) { try FileAttachments.compose(prompt: "", paths: ["/nie/ma/takiego"]) }
        let binary = try temp("x.bin", Data([0x00, 0xFF, 0x10]))
        #expect(throws: DelegateError.self) { try FileAttachments.compose(prompt: "", paths: [binary.path]) }
        let big = try temp("big.txt", Data(repeating: 0x61, count: FileAttachments.maxFileBytes + 1))
        #expect(throws: DelegateError.self) { try FileAttachments.compose(prompt: "", paths: [big.path]) }
    }

    @Test func secretsInFilesAreBlocked() async throws {
        let f = try temp("env.txt", Data("OPENAI=sk-abcdefghijklmnopqrstuvwxyz123456".utf8))
        let t = MockTransport(["api.mistral.ai": .init(status: 200, body: openAIBody)])
        let (svc, _) = try makeService(t, keys: ["MISTRAL_API_KEY": "m"])
        await #expect(throws: DelegateError.self) { try await svc.delegate(.init(prompt: "Streść", files: [f.path])) }
        #expect(t.calls.isEmpty)
    }

    @Test func fileContentIsSentAndHeaderMentionsIt() async throws {
        let f = try temp("notes.md", Data("# Notatki".utf8))
        let t = MockTransport(["api.mistral.ai": .init(status: 200, body: openAIBody)])
        let (svc, _) = try makeService(t, keys: ["MISTRAL_API_KEY": "m"])
        let out = try await svc.delegate(.init(prompt: "Streść", model: "mistral/mistral-small-latest", files: [f.path]))
        #expect(out.contains("files: 1"))
        let body = String(decoding: try #require(t.calls.first?.httpBody), as: UTF8.self)
        #expect(body.contains("# Notatki"))
    }

    @Test func replyGoesToOutputFileWithPreviewOnly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID())")
        let out = dir.appendingPathComponent("sub/pt-BR.json")
        let body = #"{"choices":[{"message":{"content":"```json\n{\"hello\": \"olá\"}\n```"}}],"usage":{"prompt_tokens":10,"completion_tokens":3}}"#
        let t = MockTransport(["api.mistral.ai": .init(status: 200, body: body)])
        let (svc, _) = try makeService(t, keys: ["MISTRAL_API_KEY": "m"])
        let text = try await svc.delegate(.init(prompt: "Translate", model: "mistral/mistral-small-latest", outputFile: out.path))
        #expect(try String(contentsOf: out, encoding: .utf8) == "{\"hello\": \"olá\"}\n")
        #expect(text.contains("Wrote \(out.path)"))
        #expect(text.contains("code fence removed"))
    }

    @Test func badOutputPathFailsBeforeCallingTheModel() async throws {
        let t = MockTransport(["api.mistral.ai": .init(status: 200, body: openAIBody)])
        let (svc, _) = try makeService(t, keys: ["MISTRAL_API_KEY": "m"])
        #expect(throws: DelegateError.self) { try svc.preflight(.init(prompt: "x", outputFile: "relative.txt")) }
        let dir = FileManager.default.temporaryDirectory.path
        await #expect(throws: DelegateError.self) { try await svc.delegate(.init(prompt: "x", outputFile: dir)) }
        #expect(t.calls.isEmpty)
    }

    @Test func syncDeadlineStopsAttemptsAndPointsToBackground() async throws {
        let t = MockTransport(["api.mistral.ai": .init(status: 200, body: openAIBody)])
        let (svc, _) = try makeService(t, keys: ["MISTRAL_API_KEY": "m"])
        do {
            _ = try await svc.delegate(.init(prompt: "x", deadlineSeconds: 1))
            Issue.record("should have run out of time")
        } catch {
            #expect("\(error)".contains("use background: true"))
        }
        #expect(t.calls.isEmpty)
        // Z zapasem czasu wywołanie przechodzi normalnie.
        #expect(try await svc.delegate(.init(prompt: "x", deadlineSeconds: 50)).contains("cześć"))
    }

    @Test func instructionsSendLongTasksToBackground() throws {
        let text = DelegationGuide(config: try Config.parse(sampleConfigToml)) { _ in true }.serverInstructions
        #expect(text.contains("cut off at 50 s"))
        #expect(DelegateJobs.maxWaitSeconds < 60)
    }

    @Test func fenceIsKeptWhenNotWrappingEverything() {
        let text = "```swift\na\n```\nmore\n```\nb\n```"
        #expect(OutputFile.stripFence(text).stripped == false)
    }

    @Test func fallbackPrefersModelsSimilarToTheChosenOne() throws {
        let (svc, _) = try makeService(MockTransport([:]), keys: ["MISTRAL_API_KEY": "m", "GEMINI_API_KEY": "g", "DEEPSEEK_API_KEY": "d"])
        let cfg = try Config.parse(sampleConfigToml)
        // codestral (code): następne powinny być modele z tagiem code, przed ogólnymi z wyższym priorytetem.
        let order = svc.candidates(for: .init(prompt: "x", model: "mistral/codestral-latest"), config: cfg).map(\.ref)
        #expect(order.first == "mistral/codestral-latest")
        let firstGeneral = try #require(order.firstIndex(of: "mistral/mistral-small-latest"))
        #expect(try #require(order.firstIndex(of: "gemini/gemini-pro-latest")) < firstGeneral)
        #expect(try #require(order.firstIndex(of: "deepseek/deepseek-chat")) < firstGeneral)
    }

    @Test func instructionsStayCompact() throws {
        var c = try Config.parse(sampleConfigToml)
        c.routingGuidance = ""
        let text = DelegationGuide(config: c) { _ in true }.serverInstructions
        // Idą w każdym zapytaniu: pilnujemy rozmiaru (ok. 4 znaki na token).
        #expect(text.count < 2600, "instrukcje mają \(text.count) znaków")
    }
}

@Suite struct BackgroundJobTests {
    @Test func jobsRunInParallelAndReportResults() async throws {
        let jobs = DelegateJobs { r in
            try await Task.sleep(for: .milliseconds(100))
            if r.prompt == "fail" { throw DelegateError(description: "boom") }
            return "result of \(r.prompt)"
        }
        let a = await jobs.start(.init(prompt: "first"))
        let b = await jobs.start(.init(prompt: "fail"))
        let c = await jobs.start(.init(prompt: "third", outputFile: "/tmp/x/pt.json"))
        #expect([a, b, c] == ["j1", "j2", "j3"])

        let early = await jobs.result(ids: [a], wait: 0)
        #expect(early.contains("j1 (first): running"))

        let started = Date()
        let all = await jobs.result(ids: [], wait: 5)
        #expect(Date().timeIntervalSince(started) < 2)   // równolegle, nie 3 × 100 ms w kolejce do limitu
        #expect(all.contains("## j1 (first): done\nresult of first"))
        #expect(all.contains("## j2 (fail): failed\nboom"))
        #expect(all.contains("## j3 (→ pt.json): done"))
        #expect(await jobs.result(ids: ["j9"], wait: 0).contains("unknown job"))
    }

    @Test func noJobsYet() async {
        #expect(await DelegateJobs { _ in "" }.result(ids: [], wait: 1) == "No background jobs.")
    }
}

@Suite struct CooldownTests {
    @Test func errorsMapToSensiblePauses() {
        func pause(_ status: Int, _ body: String) -> TimeInterval? {
            ModelCooldowns.cooldown(for: ProviderError.http(status: status, body: body))?.seconds
        }
        #expect(pause(429, "Quota exceeded ... limit: 0, model: gemini-3.1-pro") == ModelCooldowns.day)
        #expect(pause(429, "Please retry in 1h2m3.5s.") == 3723.5)
        #expect(pause(429, "Too many requests") == 60)
        #expect(pause(503, "high demand") == 300)
        #expect(pause(400, "This model only supports Interactions API.") == ModelCooldowns.week)
        #expect(pause(400, "Invalid JSON payload") == nil)   // nasz błąd, nie modelu
        #expect(pause(401, "bad key") == nil)
        #expect(ModelCooldowns.retryDelay(in: "retry after 30 seconds") == 30)
        #expect(ModelCooldowns.cooldown(for: ProviderError.network("The request timed out."))?.seconds == 300)
        // Przycięty limit wywołania synchronicznego to nie wina modelu.
        #expect(ModelCooldowns.cooldown(for: ProviderError.network("The request timed out."), fullTimeout: false) == nil)
    }

    @Test func failedModelIsSkippedUntilPauseEndsAndSuccessClearsIt() async throws {
        let t = MockTransport([
            "api.mistral.ai": .init(status: 503, body: #"{"error":{"message":"overloaded"}}"#),
            "generativelanguage.googleapis.com": .init(status: 200, body: geminiBody),
        ])
        let (svc, _) = try makeService(t, keys: ["MISTRAL_API_KEY": "m", "GEMINI_API_KEY": "g"])
        let first = try await svc.delegate(.init(prompt: "x", model: "mistral/mistral-small-latest"))
        #expect(first.contains("gemini/"))
        #expect(svc.cooldowns.active()["mistral/mistral-small-latest"] != nil)

        let cfg = try svc.currentConfig()
        let plan = svc.routingPlan(for: .init(prompt: "x"), config: cfg)
        #expect(!plan.candidates.map(\.ref).contains("mistral/mistral-small-latest"))
        #expect(plan.excluded.contains { $0.ref == "mistral/mistral-small-latest" && $0.reason.contains("overloaded (HTTP 503)") })
        let later = svc.routingPlan(for: .init(prompt: "x"), config: cfg, now: Date().addingTimeInterval(301))
        #expect(later.candidates.map(\.ref).contains("mistral/mistral-small-latest"))
        #expect(try svc.listModels().contains("PAUSED until"))
        // Kolejne wywołanie omija model na przerwie i mówi o tym w nagłówku.
        let second = try await svc.delegate(.init(prompt: "x", model: "mistral/mistral-small-latest"))
        #expect(second.contains("skipped (paused): mistral/mistral-small-latest"))
        // Fallback dalej szuka modeli podobnych do wybranego (codestral ma inne tagi niż general).
        let order = svc.routingPlan(for: .init(prompt: "x", model: "mistral/mistral-small-latest"), config: cfg).candidates.map(\.ref)
        #expect(order.first == "gemini/gemini-flash-latest")

        await #expect(throws: DelegateError.self) {
            try await svc.delegate(.init(prompt: "x", model: "mistral/mistral-small-latest", allowFallback: false))
        }
        svc.cooldowns.clear()
        #expect(svc.cooldowns.active().isEmpty)
    }

    @Test func cooldownsPersistInFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cool-\(UUID()).json")
        ModelCooldowns(url: url).set("a/b", ModelCooldown(until: Date().addingTimeInterval(60), reason: "r"))
        #expect(ModelCooldowns(url: url).active()["a/b"]?.reason == "r")
        ModelCooldowns(url: url).clear("a/b")
        #expect(ModelCooldowns(url: url).active().isEmpty)
    }
}
