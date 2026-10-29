import Foundation
import Testing
@testable import DelegateCore

/// Repo gita: zacommitowany `notes.txt`, potem niezacommitowana zmiana i nieśledzony `.env` z sekretem.
func makeRepo() throws -> URL {
    let repo = try tempDir("repo")
    func git(_ args: String...) throws { try RepoSnapshot.git(args, in: repo) }
    try git("init", "-q")
    try git("config", "user.email", "test@example.com")
    try git("config", "user.name", "Test")
    try "committed\n".write(to: repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try git("add", "notes.txt")
    try git("commit", "-q", "-m", "init")
    try "uncommitted\n".write(to: repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try "SECRET=1\n".write(to: repo.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    return repo
}

@Suite(.enabled(if: pythonAvailable && AgentSandbox.isAvailable)) struct AgentRunTests {
    private func runner() throws -> AgentRunner {
        AgentRunner(home: DelegateHome(directory: try tempDir("home")), workRoot: try tempDir("work"),
                    userHome: try tempDir("user"))
    }

    private func agent(_ scenario: String, env: [String: String] = [:]) throws -> InstalledAgent {
        let exe = try writeFakeAgent(in: try tempDir("bin"))
        return InstalledAgent(id: "fake", name: "Fake Agent", version: "1", executable: exe.path, args: [],
                              env: env.merging(["FAKE_SCENARIO": scenario]) { a, _ in a }, installedAt: Date())
    }

    @Test func silentAgentEndsAfterTheIdleLimitNotTheFullTimeout() async throws {
        let started = Date()
        do {
            _ = try await runner().run(agent: try agent("hang"), repo: try makeRepo(), task: "Never answers",
                                       timeout: .seconds(60), idleLimit: .seconds(2))
            Issue.record("expected the watchdog to stop the agent")
        } catch let e as DelegateError {
            #expect(e.description.hasPrefix("Fake Agent stopped responding (nothing for "))
            #expect(Date().timeIntervalSince(started) < 30)
            #expect(AgentPause.pause(after: e.description, previousError: e.description)?.kind == .timeouts)
        }
    }

    @Test func readOnlySnapshotInSandbox() async throws {
        let repo = try makeRepo()
        let secret = repo.appendingPathComponent(".env").path
        let report = try await runner().run(agent: try agent("probe", env: ["FAKE_SECRET": secret]),
                                            repo: repo, task: "Check things", model: "m2", effort: "low")
        let text = report.text
        #expect(text.contains("read:uncommitted"))   // kopia ma niezacommitowane zmiany
        #expect(text.contains("write:blocked"))      // kopia repo tylko do odczytu
        #expect(text.contains("env:no"))             // pliki nieśledzone nie trafiają do kopii
        #expect(text.contains("secret:blocked"))     // oryginalne repo niewidoczne…
        #expect(text.contains("git:ok"))             // …poza jego .git, z którego korzysta kopia
        #expect(text.contains("tmp:ok"))             // katalog tymczasowy zadania zapisywalny
        #expect(text.contains("model:m2"))
        #expect(text.contains("effort:low"))
        #expect(report.effort == "low")
        #expect(text.contains("cwd:" + (try RepoSnapshot.git(["rev-parse", "--show-toplevel"], in: repo))))   // ścieżki kopii zamienione na oryginał
        #expect(!text.contains("agent-jobs") && !text.contains("/repo "))
        #expect(text.contains("got: Check things"))
        #expect(text.contains("permission: reject"))
        #expect(report.rejected.count == 1)
        #expect(report.toolCalls.map(\.title) == ["grep notes"])
        #expect(report.inputTokens == 100)
        #expect(report.outputTokens == 7)
        #expect(report.model == "m2")
        #expect(report.includesUncommitted)
        #expect(report.mode == "ask")   // atrapa ma tryby ask/auto, nie plan
        #expect(report.formatted.hasPrefix("[delegate_agent] agent: Fake Agent · model: m2 · effort: low · mode: ask · tokens: 100 in / 7 out"))
        #expect(report.formatted.contains("Blocked (read-only):"))

        // Oryginał nietknięty, kopia posprzątana.
        #expect(try String(contentsOf: repo.appendingPathComponent("notes.txt"), encoding: .utf8) == "uncommitted\n")
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("x.txt").path))
        let worktrees = try RepoSnapshot.git(["worktree", "list"], in: repo).split(separator: "\n")
        #expect(worktrees.count == 1)
    }

    @Test func commandsAreAllowedInSandboxButEditsAreNot() async throws {
        let report = try await runner().run(agent: try agent("ok", env: ["FAKE_PERM_KIND": "execute"]),
                                            repo: try makeRepo(), task: "x")
        #expect(report.text.contains("permission: allow"))
        #expect(report.rejected.isEmpty)
        // Bez piaskownicy nawet polecenie dostaje odmowę.
        let bare = AgentRunner(home: DelegateHome(directory: try tempDir("home")), workRoot: try tempDir("work"),
                               useSandbox: false, userHome: try tempDir("user"))
        let strict = try await bare.run(agent: try agent("ok", env: ["FAKE_PERM_KIND": "execute"]), repo: try makeRepo(), task: "x")
        #expect(strict.text.contains("permission: reject"))
    }

    @Test func successfulJobLeavesNoWorkDirectory() async throws {
        let work = try tempDir("work")
        let r = AgentRunner(home: DelegateHome(directory: try tempDir("home")), workRoot: work, userHome: try tempDir("user"))
        _ = try await r.run(agent: try agent("ok"), repo: try makeRepo(), task: "x")
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
    }

    @Test func unknownModelListsTheValidOnes() async throws {
        do {
            _ = try await runner().run(agent: try agent("ok"), repo: try makeRepo(), task: "x", model: "nope")
            Issue.record("expected error")
        } catch let e as DelegateError {
            #expect(e.description.contains("available: m1, m2"))
        }
    }

    @Test func unknownEffortListsTheValidOnes() async throws {
        do {
            _ = try await runner().run(agent: try agent("ok"), repo: try makeRepo(), task: "x", effort: "turbo")
            Issue.record("expected error")
        } catch let e as DelegateError {
            #expect(e.description.contains("available: default, low, high"))
        }
    }

    @Test func missingSignInIsExplained() async throws {
        do {
            _ = try await runner().run(agent: try agent("auth"), repo: try makeRepo(), task: "x")
            Issue.record("expected error")
        } catch let e as DelegateError {
            #expect(e.description.contains("isn't signed in (Sign in)"))
        }
    }

    @Test func notARepository() async throws {
        await #expect(throws: DelegateError.self) {
            _ = try await runner().run(agent: try agent("ok"), repo: try tempDir("plain"), task: "x")
        }
    }
}

@Suite struct AgentSandboxProfileTests {
    @Test func laterRulesNarrowEarlierOnes() {
        let home = URL(fileURLWithPath: "/Users/u")
        let profile = AgentSandbox(home: home, writable: [home.appendingPathComponent(".vibe")],
                                   readOnly: [URL(fileURLWithPath: "/Users/u/Library/Caches/x/repo")],
                                   hidden: [URL(fileURLWithPath: "/Users/u/.ssh"), URL(fileURLWithPath: "/Users/u/we\"ird")]).profile()
        let lines = profile.split(separator: "\n").map(String.init)
        #expect(lines[1] == "(allow default)")
        #expect(lines[2].hasPrefix("(deny file-write* (subpath \"/Users/u\")"))
        #expect(lines[3] == "(allow file-write* (subpath \"/Users/u/.vibe\"))")
        #expect(lines[4] == "(deny file-write* (subpath \"/Users/u/Library/Caches/x/repo\"))")
        #expect(lines[5].contains("(subpath \"/Users/u/we\\\"ird\")"))
    }

    @Test func tmpPathsAreResolved() {
        #expect(AgentSandbox.realPath(URL(fileURLWithPath: "/tmp/a")) == "/private/tmp/a")
    }
}

@Suite struct AgentRegionTests {
    @Test func sensitivityDecidesWhichAgentsMayGetTheRepo() throws {
        let config = Config()
        #expect(AgentRegions.refusal(agentID: "mistral-vibe", sensitivity: .public, config: config) == nil)
        #expect(AgentRegions.refusal(agentID: "mistral-vibe", sensitivity: .personal, config: config) == nil)
        #expect(AgentRegions.refusal(agentID: "kimi", sensitivity: .personal, config: config) != nil)
        #expect(AgentRegions.refusal(agentID: "unknown", sensitivity: .personal, config: config) != nil)
        #expect(AgentRegions.refusal(agentID: "mistral-vibe", sensitivity: .private, config: config) != nil)
    }

    @Test func agentSettingsRoundTripMergeAndShowInInstructions() throws {
        var config = try Config.parse(sampleConfigToml)
        config.setAgent("claude-acp", model: "haiku", effort: "low")
        config.setAgent("mistral-vibe", model: " ", effort: nil)   // puste = brak wpisu
        #expect(config.agents == [AgentSettings(id: "claude-acp", model: "haiku", effort: "low")])
        let toml = try config.serialized()
        #expect(toml.contains("[[agent]]\nid = \"claude-acp\"\nmodel = \"haiku\"\neffort = \"low\""))
        #expect(try Config.parse(toml).agents == config.agents)

        // Scalanie: GUI zmienia agenta, z zewnątrz ktoś zmienia dostawcę — zostają obie zmiany.
        var mine = config, theirs = config
        mine.setAgent("claude-acp", model: "sonnet", effort: "low")
        theirs.timeoutSeconds = 90
        let merged = Config.merge(base: config, mine: mine, theirs: theirs)
        #expect(merged.agentSettings("claude-acp")?.model == "sonnet")
        #expect(merged.timeoutSeconds == 90)

        // Wpis bez ustawień zostaje jako samo `id`: jego miejsce to priorytet.
        config.setAgent("claude-acp", model: nil, effort: nil)
        #expect(config.agents == [AgentSettings(id: "claude-acp")])
        #expect(try config.serialized().contains("[[agent]]\nid = \"claude-acp\"\n"))

        var withDefaults = try Config.parse(sampleConfigToml)
        withDefaults.setAgent("claude-acp", model: "haiku", effort: "low")
        let text = DelegationGuide(config: withDefaults, agents: ["mistral-vibe", "claude-acp"]) { _ in true }.serverInstructions
        #expect(text.contains("pick another only for a reason): mistral-vibe; claude-acp: haiku, low. "))
    }

    @Test func instructionsMentionAgentsOnlyWhenInstalled() throws {
        let config = try Config.parse(sampleConfigToml)
        #expect(!DelegationGuide(config: config) { _ in true }.serverInstructions.contains("delegate_agent"))
        let text = DelegationGuide(config: config, agents: ["mistral-vibe"]) { _ in true }.serverInstructions
        #expect(text.contains("`delegate_agent` runs a coding agent on a git repo"))
        #expect(text.contains("for a reason): mistral-vibe. "))
    }
}

@Suite struct JobPersistenceTests {
    @Test func resultsSurviveARestart() async throws {
        let dir = try tempDir("jobs")
        let first = DelegateJobs(run: { _ in "" }, store: JobStore(directory: dir))
        let id = await first.start(label: "agent: find X") { "the report" }
        #expect(id.hasPrefix("j") && id.count == 6)
        _ = await first.result(ids: [id], wait: 5)

        // Nowy proces serwera (nowy obiekt) czyta wynik z dysku.
        let second = DelegateJobs(run: { _ in "" }, store: JobStore(directory: dir))
        #expect(await second.result(ids: [id], wait: 0) == "## \(id) (agent: find X): done\nthe report")
        #expect(await second.result(ids: ["../etc"], wait: 0).contains("unknown job"))
    }

    @Test func jobOfADeadProcessIsReportedAsInterrupted() async throws {
        let dir = try tempDir("jobs")
        let record = #"{"id":"jdead1","label":"agent: x","started":"2026-10-27T10:00:00Z","state":"running","pid":999999}"#
        try record.write(to: dir.appendingPathComponent("jdead1.json"), atomically: true, encoding: .utf8)
        let jobs = DelegateJobs(run: { _ in "" }, store: JobStore(directory: dir))
        #expect(await jobs.result(ids: ["jdead1"], wait: 0).contains("interrupted"))
    }

    @Test func detailsAndBranchAreStoredForTheApp() async throws {
        let dir = try tempDir("jobs")
        let store = JobStore(directory: dir)
        let jobs = DelegateJobs(run: { _ in "" }, store: store)
        let details = DelegateJobs.Details(agent: "claude-acp", model: "haiku", repo: "/repo", write: true)
        let id = await jobs.start(label: "claude-acp (write): add tests", details: details) {
            .init(text: "report", branch: "delegate/claude-acp-add-tests-abc123")
        }
        _ = await jobs.result(ids: [id], wait: 5)
        let other = await jobs.start(label: "→ notes.md") { "text" }
        _ = await jobs.result(ids: [other], wait: 5)

        let all = store.all()
        #expect(all.map(\.id) == [other, id])
        let stored = try #require(all.last)
        #expect(stored.job.details == DelegateJobs.Details(agent: "claude-acp", model: "haiku", repo: "/repo", write: true,
                                                            branch: "delegate/claude-acp-add-tests-abc123"))
        #expect(stored.job.state == .done("report") && stored.job.finished != nil && !stored.interrupted)
        #expect(all.first?.job.details == nil)

        store.remove(id)
        #expect(store.all().map(\.id) == [other])
    }

    @Test func failedJobKeepsTheBranchOfUnfinishedWork() async throws {
        let dir = try tempDir("jobs")
        let store = JobStore(directory: dir)
        let jobs = DelegateJobs(run: { _ in "" }, store: store)
        let id = await jobs.start(label: "vibe (write): x", details: .init(agent: "vibe", write: true)) { () throws -> String in
            throw DelegateError(description: "Vibe didn't finish", branch: "delegate/vibe-x-abc123")
        }
        _ = await jobs.result(ids: [id], wait: 5)
        let stored = try #require(store.all().first)
        #expect(stored.job.state == .failed("Vibe didn't finish"))
        #expect(stored.job.details?.branch == "delegate/vibe-x-abc123")
    }

    @Test func runningJobOfALiveServerIsNotRemoved() async throws {
        let dir = try tempDir("jobs")
        let store = JobStore(directory: dir)
        let jobs = DelegateJobs(run: { _ in "" }, store: store)
        let id = await jobs.start(label: "slow") {
            try await Task.sleep(for: .seconds(5))
            return "late"
        }
        store.remove(id)
        #expect(store.all().map(\.id) == [id])
    }

    @Test func purgeRemovesOldFiles() throws {
        let dir = try tempDir("jobs")
        let old = dir.appendingPathComponent("jold.json")
        try "{}".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: old.path)
        JobStore(directory: dir).purge()
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }
}

@Suite(.enabled(if: pythonAvailable)) struct AgentAccountTests {
    private func agent(_ scenario: String) throws -> InstalledAgent {
        let exe = try writeFakeAgent(in: try tempDir("bin"))
        return InstalledAgent(id: "fake", name: "Fake Agent", version: "1", executable: exe.path, args: [],
                              env: ["FAKE_SCENARIO": scenario], installedAt: Date())
    }

    @Test func signedInAgentReportsItsModels() async throws {
        let check = await AgentAccount.check(try agent("ok"))
        #expect(check.signIn == .signedIn)
        #expect(check.models == ["m1", "m2"])
        #expect(check.defaultModel == "m1")
        #expect(check.efforts == ["default", "low", "high"])
        #expect(check.defaultEffort == "default")
        #expect(check.authMethods.map(\.id) == ["browser-auth", "setup", "legacy"])
    }

    @Test func agentWithoutLoginOffersMethods() async throws {
        let check = await AgentAccount.check(try agent("auth"))
        guard case .needsSignIn(let methods) = check.signIn else {
            Issue.record("expected needsSignIn, got \(check.signIn)"); return
        }
        #expect(methods.map(\.type) == ["agent", "terminal", "terminal"])
    }

    @Test func brokenAgentIsReportedNotHung() async throws {
        let check = await AgentAccount.check(try agent("crash"))
        guard case .failed = check.signIn else { Issue.record("expected failure"); return }
    }

    @Test func browserSignInCallsAuthenticate() async throws {
        let a = try agent("auth")
        let methods = await AgentAccount.check(a).authMethods
        try await AgentAccount.signIn(a, method: methods[0])
        await #expect(throws: ACPConnection.RemoteError.self) { try await AgentAccount.signIn(a, method: methods[1]) }
    }

    @Test func terminalCommandIsQuoted() {
        let a = InstalledAgent(id: "x", name: "X", version: "1", executable: "/Apps/My Agent/agent", args: ["--acp"],
                               env: ["A": "it's"], installedAt: Date())
        let m = ACPAgentHello.AuthMethod(id: "t", name: "T", type: "terminal", args: ["--setup"], env: ["B": "2"])
        #expect(AgentAccount.terminalCommand(a, method: m) == "A='it'\\''s' B='2' '/Apps/My Agent/agent' '--setup'")
        // Osobny program logowania (Copilot: `copilot login`) zamiast samego agenta.
        let legacy = ACPAgentHello.AuthMethod(id: "l", name: "L", type: "terminal", args: ["login"], command: "/opt/copilot")
        #expect(AgentAccount.terminalCommand(a, method: legacy) == "A='it'\\''s' '/opt/copilot' 'login'")
    }
}

@Suite struct AgentRulesTests {
    @Test func settingsRoundTripAndPartialUpdatesKeepOtherFields() throws {
        var c = Config()
        c.updateAgent("copilot") { $0.enabled = false; $0.privacy = .eu }
        c.setAgent("copilot", model: "gpt", effort: nil)
        #expect(c.agentSettings("copilot") == AgentSettings(id: "copilot", model: "gpt", enabled: false, privacy: .eu))
        c.repos = [RepoRule(path: "~/Work", agents: []), RepoRule(path: "~/Work/oss", agents: ["mistral-vibe"])]
        let parsed = try Config.parse(try c.serialized())
        #expect(parsed.agents == c.agents)
        #expect(parsed.repos == c.repos)
        // Włączenie z powrotem to brak pola, a nie `enabled = true`.
        c.updateAgent("copilot") { $0.enabled = true }
        #expect(c.agentSettings("copilot")?.enabled == nil)
    }

    @Test func mostSpecificRepoRuleWins() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var c = Config()
        c.repos = [RepoRule(path: "~/Work", agents: []), RepoRule(path: "~/Work/oss", agents: ["mistral-vibe"])]
        #expect(c.repoRule(for: home.appendingPathComponent("Work/company/app"))?.path == "~/Work")
        #expect(c.repoRule(for: home.appendingPathComponent("Work/oss/lib"))?.path == "~/Work/oss")
        #expect(c.repoRule(for: home.appendingPathComponent("Workshop")) == nil)   // prefiks nazwy to nie przodek
        #expect(c.repoRule(for: home.appendingPathComponent("Private")) == nil)
    }

    @Test func refusalCombinesSwitchRepoRuleAndRegion() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var c = Config()
        c.repos = [RepoRule(path: "~/Work", agents: ["mistral-vibe"])]
        let work = home.appendingPathComponent("Work/app")
        #expect(AgentRegions.refusal(agentID: "mistral-vibe", sensitivity: .public, config: c, repo: work) == nil)
        #expect(AgentRegions.refusal(agentID: "github-copilot-cli", sensitivity: .public, config: c, repo: work)?
            .contains("allows only mistral-vibe for ~/Work") == true)
        c.updateAgent("mistral-vibe") { $0.enabled = false }
        #expect(AgentRegions.refusal(agentID: "mistral-vibe", sensitivity: .public, config: c, repo: work)?
            .contains("turned off") == true)
        // Region z ustawień zastępuje tabelę: nieznany agent ustawiony na EU przyjmie dane osobiste.
        #expect(AgentRegions.refusal(agentID: "unknown", sensitivity: .personal, config: c) != nil)
        c.updateAgent("unknown") { $0.privacy = .eu }
        #expect(AgentRegions.refusal(agentID: "unknown", sensitivity: .personal, config: c) == nil)
    }

    @Test func listModelsDescribesAgentsFromTheCheckCache() throws {
        let cache = AgentCheckCache(url: try tempDir("checks").appendingPathComponent("checks.json"))
        let check = AgentAccount.Check(signIn: .signedIn, models: ["default", "haiku", "sonnet"], defaultModel: "default",
                                       authMethods: [], efforts: ["low", "high"], defaultEffort: "high")
        cache.save("claude-acp", AgentCheckRecord(check))
        cache.save("vibe", AgentCheckRecord(.init(signIn: .needsSignIn([]), models: [], defaultModel: nil, authMethods: [])))
        var c = Config()
        c.setAgent("claude-acp", model: "haiku", effort: nil)
        c.updateAgent("off") { $0.enabled = false }
        c.repos = [RepoRule(path: "~/Work", agents: [])]
        let agents = ["claude-acp", "vibe", "off"].map {
            InstalledAgent(id: $0, name: $0.uppercased(), version: "1", executable: "/x", args: [], env: [:], installedAt: Date())
        }
        let text = AgentCatalog.describe(installed: agents, config: c, checks: cache.load())
        #expect(text.contains("- `claude-acp` (CLAUDE-ACP) · region us"))
        #expect(text.contains("models: haiku, sonnet (default: haiku)"))
        #expect(text.contains("effort: low, high (default: high)"))
        #expect(text.contains("`vibe` (VIBE) · region other · NOT signed in"))
        #expect(text.contains("`off` (OFF) · region other · turned off by the user"))
        #expect(text.contains("Repository rules: ~/Work → no agents"))
        #expect(AgentCatalog.describe(installed: [], config: c, checks: [:]).isEmpty)
    }
}

@Suite struct AgentPriorityTests {
    private let installed = ["antigravity-acp", "claude-acp", "codex-acp", "mistral-vibe"]

    @Test func configOrderIsPriorityAndSurvivesReorderAndRoundTrip() throws {
        var c = Config()
        #expect(c.prioritizedAgents(installed) == installed)   // bez configu: kolejność instalacji
        c.updateAgent("codex-acp") { $0.guidance = "Free plan with limits,\nslow" }
        c.reorderAgents(["mistral-vibe", "claude-acp", "codex-acp"])
        #expect(c.prioritizedAgents(installed) == ["mistral-vibe", "claude-acp", "codex-acp", "antigravity-acp"])
        #expect(c.agentSettings("codex-acp")?.guidance == "Free plan with limits, slow")
        // Wpis odinstalowanego agenta zostaje z ustawieniami, na końcu.
        c.updateAgent("old") { $0.model = "x" }
        c.reorderAgents(["claude-acp", "mistral-vibe"])
        #expect(c.agents.map(\.id) == ["claude-acp", "mistral-vibe", "codex-acp", "old"])
        let parsed = try Config.parse(try c.serialized())
        #expect(parsed.agents == c.agents)
    }

    @Test func pickTakesTheFirstAllowedAndSaysWhoWasSkipped() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var c = Config()
        c.repos = [RepoRule(path: "~/Work", agents: ["claude-acp", "codex-acp"])]
        let checks = ["claude-acp": AgentCheckRecord(.init(signIn: .needsSignIn([]), models: [], defaultModel: nil, authMethods: []))]
        let order = ["mistral-vibe", "claude-acp", "codex-acp"]

        let free = AgentChoice.pick(from: order, sensitivity: .public, config: c, repo: home.appendingPathComponent("Code/x"),
                                    checks: checks, clientName: nil)
        #expect(free == .init(agent: "mistral-vibe", skipped: []))

        let work = AgentChoice.pick(from: order, sensitivity: .public, config: c, repo: home.appendingPathComponent("Work/app"),
                                    checks: checks, clientName: nil)
        #expect(work.agent == "codex-acp")
        #expect(work.skipped.map(\.ref) == ["mistral-vibe", "claude-acp"])
        #expect(work.skipped[1].reason.contains("not signed in"))

        let none = AgentChoice.pick(from: order, sensitivity: .private, config: c, repo: nil, checks: [:], clientName: nil)
        #expect(none.agent == nil && none.skipped.count == 3)
        let text = AgentChoice.refusal(none)
        #expect(text.contains("Skipped:\n- mistral-vibe: private data stays on this Mac"))
        #expect(text.contains("What to do:") && text.contains("do the task yourself"))
    }

    @Test func conductorsOwnAgentIsPickedOnlyWithACheaperDefault() {
        var c = Config()
        let order = ["claude-acp", "mistral-vibe"]
        let skip = AgentChoice.pick(from: order, sensitivity: .public, config: c, repo: nil, checks: [:], clientName: "claude-code")
        #expect(skip.agent == "mistral-vibe")
        #expect(skip.skipped.first?.reason.contains("same subscription") == true)
        c.setAgent("claude-acp", model: "haiku", effort: "low")
        #expect(AgentChoice.pick(from: order, sensitivity: .public, config: c, repo: nil, checks: [:], clientName: "claude-code").agent == "claude-acp")
        #expect(AgentChoice.pick(from: order, sensitivity: .public, config: Config(), repo: nil, checks: [:], clientName: "codex").agent == "claude-acp")
    }

    @Test func guidanceAndOrderReachTheConductor() throws {
        var c = try Config.parse(sampleConfigToml)
        c.updateAgent("mistral-vibe") { $0.guidance = "Default for analysis; fast." }
        c.reorderAgents(["mistral-vibe", "antigravity-acp"])
        let text = DelegationGuide(config: c, agents: c.prioritizedAgents(["antigravity-acp", "mistral-vibe"])) { _ in true }.serverInstructions
        #expect(text.contains("for a reason): mistral-vibe — Default for analysis; fast.; antigravity-acp. "))

        let agents = ["antigravity-acp", "mistral-vibe"].map {
            InstalledAgent(id: $0, name: $0, version: "1", executable: "/x", args: [], env: [:], installedAt: Date())
        }
        let catalog = AgentCatalog.describe(installed: agents, config: c, checks: [:])
        let vibe = try #require(catalog.range(of: "`mistral-vibe`")), anti = try #require(catalog.range(of: "`antigravity-acp`"))
        #expect(vibe.lowerBound < anti.lowerBound)
        #expect(catalog.contains("  guidance: Default for analysis; fast.\n"))
    }
}

@Suite struct AgentPauseTests {
    @Test func failuresMapToPauses() {
        let signIn = AgentPause.pause(after: "Codex isn't signed in (ChatGPT). Sign in to the agent first, then retry.", previousError: nil)
        #expect(signIn?.kind == .signIn && signIn?.seconds == ModelCooldowns.week)
        let reset = AgentPause.pause(after: "You've hit your usage limit. Please retry in 2h0m0s.", previousError: nil)
        #expect(reset?.kind == .limit && reset?.seconds == 7200)
        #expect(AgentPause.pause(after: "HTTP 429: rate limit exceeded", previousError: nil)?.seconds == 3600)
        // Jeden limit czasu to jeszcze nie powód; drugi z rzędu tak.
        let timeout = "Codex didn't finish in 600 seconds.\nPartial report:\nchecked the quota module"
        #expect(AgentPause.pause(after: timeout, previousError: nil) == nil)
        #expect(AgentPause.pause(after: timeout, previousError: "agent exited (status 1)") == nil)
        #expect(AgentPause.pause(after: timeout, previousError: "X stopped responding (nothing for 180 s).")?.kind == .timeouts)
        #expect(AgentPause.pause(after: "agent exited (status 3)", previousError: nil) == nil)
    }

    @Test func pausedAgentsAreSkippedAndShown() {
        let pause = ModelCooldown(until: Date().addingTimeInterval(600), reason: "plan or rate limit reached")
        let choice = AgentChoice.pick(from: ["codex-acp", "mistral-vibe"], sensitivity: .public, config: Config(), repo: nil,
                                      checks: [:], clientName: nil, paused: [AgentPause.key("codex-acp"): pause])
        #expect(choice.agent == "mistral-vibe")
        #expect(choice.skipped.first?.kind == .pause && choice.skipped.first?.reason.contains("plan or rate limit") == true)

        let now = Date()
        let usage = [
            UsageEntry(ts: now, provider: "agent:codex-acp", model: "m", ok: true, ms: 90_000),
            UsageEntry(ts: now, provider: "agent:codex-acp", model: "m", ok: true, ms: 330_000),
            UsageEntry(ts: now, provider: "agent:codex-acp", model: "m", ok: false, error: "x", ms: 600_000),
            UsageEntry(ts: now, provider: "codex-acp", model: "m", ok: true, ms: 1),
        ]
        let agent = InstalledAgent(id: "codex-acp", name: "Codex", version: "1", executable: "/x", args: [], env: [:], installedAt: now)
        let text = AgentCatalog.describe(installed: [agent], config: Config(), checks: [:], usage: usage,
                                         paused: [AgentPause.key("codex-acp"): pause])
        #expect(text.contains("· PAUSED until "))
        #expect(text.contains("  last 30 days: 3 runs, 2 ok, median 5m 30s\n"))
    }
}

@Suite(.enabled(if: pythonAvailable && AgentSandbox.isAvailable)) struct AgentWriteModeTests {
    private func runner() throws -> AgentRunner {
        AgentRunner(home: DelegateHome(directory: try tempDir("home")), workRoot: try tempDir("work"),
                    userHome: try tempDir("user"))
    }

    private func agent(_ scenario: String, env: [String: String] = [:]) throws -> InstalledAgent {
        let exe = try writeFakeAgent(in: try tempDir("bin"))
        return InstalledAgent(id: "fake", name: "Fake Agent", version: "1", executable: exe.path, args: [],
                              env: env.merging(["FAKE_SCENARIO": scenario]) { a, _ in a }, installedAt: Date())
    }

    @Test func changesLandOnABranchAndNothingElseIsTouched() async throws {
        let repo = try makeRepo()   // ma też niezacommitowaną zmianę notes.txt i nieśledzony .env
        let outside = repo.appendingPathComponent("outside.txt").path
        let report = try await runner().run(agent: try agent("writer", env: ["FAKE_OUTSIDE": outside]),
                                            repo: repo, task: "Add a line to notes", write: true, jobID: "ABC123XYZ")
        #expect(report.text.contains("outside:blocked"))   // oryginalne repo nietykalne
        #expect(report.text.contains("hook:blocked"))      // hooki gita nietykalne
        #expect(report.text.contains("status:ok"))         // git działa w worktree
        #expect(report.text.contains("permission: allow")) // w trybie zapisu edycje są zatwierdzane
        #expect(report.mode == nil)                          // atrapa nie ma trybu acceptEdits

        let branch = try #require(report.branch)
        #expect(branch.branch == "delegate/fake-add-a-line-to-notes-abc123")
        #expect(branch.commits == 1)
        #expect(branch.summary.contains("2 files changed"))
        #expect(report.uncommittedLeftOut)
        #expect(report.formatted.contains("Merge: `git merge --squash delegate/fake-add-a-line-to-notes-abc123`"))

        // Gałąź jest w repo użytkownika, jego working tree bez zmian, worktree posprzątany.
        let show = try RepoSnapshot.git(["show", "--stat", "--format=%an|%s", branch.branch], in: repo)
        #expect(show.contains("Delegate (Fake Agent)|Fake Agent: Add a line to notes"))
        #expect(try RepoSnapshot.git(["show", "\(branch.branch):notes.txt"], in: repo) == "committed\nagent line")
        #expect(try String(contentsOf: repo.appendingPathComponent("notes.txt"), encoding: .utf8) == "uncommitted\n")
        #expect(!FileManager.default.fileExists(atPath: outside))
        #expect(try RepoSnapshot.git(["worktree", "list"], in: repo).split(separator: "\n").count == 1)
    }

    @Test func contextReachesTheAgentButNotTheCommit() async throws {
        let repo = try makeRepo()
        let context = AgentContext(items: [.init(name: "j1.md", source: "report of job j1", text: "use tabs")],
                                   sensitivity: .public)
        let report = try await runner().run(agent: try agent("writer", env: ["FAKE_READ": ".delegate-context/j1.md"]),
                                            repo: repo, task: "Apply the report", write: true, context: context,
                                            jobID: "ctx1234")
        #expect(report.text.contains("ctx:use tabs"))
        #expect(report.text.contains("got: Apply the report"))   // notka o kontekście idzie przed zadaniem
        let branch = try #require(report.branch?.branch)
        let files = try RepoSnapshot.git(["ls-tree", "-r", "--name-only", branch], in: repo)
        #expect(!files.contains(AgentContext.directory))
        #expect(files.contains("new.txt"))
    }

    @Test func followUpRoundContinuesOnTheAgentBranch() async throws {
        let repo = try makeRepo()
        let r = try runner()
        let first = try await r.run(agent: try agent("writer"), repo: repo, task: "Round one", write: true, jobID: "aaaaaa1")
        let firstBranch = try #require(first.branch?.branch)
        let second = try await r.run(agent: try agent("writer"), repo: repo, task: "Round two", write: true,
                                     branchFrom: firstBranch, jobID: "bbbbbb2")
        let b = try #require(second.branch)
        #expect(b.commits == 1)   // tylko nowa runda, licząc od gałęzi pierwszej
        #expect(try RepoSnapshot.git(["show", "\(b.branch):notes.txt"], in: repo) == "committed\nagent line\nagent line")
        await #expect(throws: DelegateError.self) {
            _ = try await r.run(agent: try agent("writer"), repo: repo, task: "x", write: true, branchFrom: "delegate/missing")
        }
    }

    @Test func failedCheckGetsAFixRoundInTheSameSession() async throws {
        let repo = try makeRepo()
        // Atrapa dopisuje „agent line” przy każdym prompcie: check przechodzi dopiero po drugim, czyli po jednej poprawce.
        let check = "test $(grep -c 'agent line' notes.txt) -ge 2"
        let report = try await runner().run(agent: try agent("writer"), repo: repo, task: "Add lines to notes", write: true,
                                            check: check, jobID: "ddddddd4")
        let result = try #require(report.check)
        #expect(result.passed && result.fixes == 1)
        #expect(report.formatted.contains("✓ check `\(check)` passed after 1 fix"))
        #expect(report.formatted.contains("Agent's summary:"))
        let branch = try #require(report.branch)
        #expect(try RepoSnapshot.git(["show", "\(branch.branch):notes.txt"], in: repo) == "committed\nagent line\nagent line")
    }

    @Test func timeoutKeepsUnfinishedWorkOnABranchAndReportsIt() async throws {
        let repo = try makeRepo()
        do {
            _ = try await runner().run(agent: try agent("writehang"), repo: repo, task: "Half a job", write: true,
                                       timeout: .seconds(2), jobID: "cccccc3")
            Issue.record("expected a timeout")
        } catch let e as DelegateError {
            #expect(e.branch == "delegate/fake-half-a-job-cccccc")
            #expect(e.description.contains("Unfinished changes are on branch `delegate/fake-half-a-job-cccccc`"))
            #expect(try RepoSnapshot.git(["show", "\(e.branch ?? ""):notes.txt"], in: repo) == "committed\nhalf done")
        }
    }

    @Test func noChangesMeansNoBranch() async throws {
        let repo = try makeRepo()
        let report = try await runner().run(agent: try agent("noop"), repo: repo, task: "Look around", write: true)
        #expect(report.branch?.commits == 0)
        #expect(report.formatted.contains("No changes were made; the branch was removed."))
        #expect(try RepoSnapshot.git(["branch", "--list", "delegate/*"], in: repo).isEmpty)
    }

    @Test func branchNamesAreSafe() {
        #expect(RepoSnapshot.branchName(agent: "claude-acp", task: "Przetłumacz pliki na pt-BR!", id: "J1A2B3C4")
            == "delegate/claude-acp-przet-umacz-pliki-na-pt-j1a2b3")
        #expect(RepoSnapshot.branchName(agent: "x", task: "", id: "j1") == "delegate/x-j1")
    }
}

@Suite struct AgentSlotsTests {
    @Test func onlyLimitRunAtOnce() async {
        let slots = AgentSlots(limit: 2)
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await slots.acquire()
                    await counter.enter()
                    try? await Task.sleep(for: .milliseconds(30))
                    await counter.leave()
                    await slots.release()
                }
            }
        }
        #expect(await counter.peak == 2)
    }

    actor Counter {
        var now = 0, peak = 0
        func enter() { now += 1; peak = max(peak, now) }
        func leave() { now -= 1 }
    }
}

@Suite struct SwarmSkillTests {
    @Test func stateDistinguishesOursFromAForeignSkill() {
        #expect(SwarmSkill.state(of: nil) == .notInstalled)
        #expect(SwarmSkill.state(of: SwarmSkill.content) == .installed)
        #expect(SwarmSkill.state(of: SwarmSkill.content + "\nedited") == .outdated)
        #expect(SwarmSkill.state(of: "---\nname: swarm\n---\nsomeone else's skill") == .foreign)
    }

    @Test func skillIsAValidClaudeCodeSkillThatUsesTheTools() {
        let text = SwarmSkill.content
        #expect(text.hasPrefix("---\nname: swarm\ndescription: "))
        for needle in ["$ARGUMENTS", "list_models", "delegate_agent", "mode: \"write\"", "branch_from",
                       "delegate_result", "git merge --squash", "output_file", "sensitivity"] {
            #expect(text.contains(needle), "missing \(needle)")
        }
        #expect(text.count < 6000, "skill has \(text.count) characters")
    }
}

@Suite struct AssistantClientTests {
    @Test func clientNamesMapToTheirOwnAgent() {
        #expect(AssistantClient.sameSubscriptionAgent(clientName: "claude-code") == "claude-acp")
        #expect(AssistantClient.sameSubscriptionAgent(clientName: "claude-ai") == "claude-acp")
        #expect(AssistantClient.sameSubscriptionAgent(clientName: "codex-mcp-client") == "codex-acp")
        #expect(AssistantClient.sameSubscriptionAgent(clientName: "cursor-vscode") == "cursor")
        #expect(AssistantClient.sameSubscriptionAgent(clientName: "Visual Studio Code") == "github-copilot-cli")
        #expect(AssistantClient.sameSubscriptionAgent(clientName: "zed") == nil)
        #expect(AssistantClient.sameSubscriptionAgent(clientName: nil) == nil)
    }

    @Test func hintOnlyWhenTheOwnAgentIsInstalledAndShowsDefaults() {
        var c = Config()
        #expect(AssistantClient.hint(clientName: "claude-code", agents: ["mistral-vibe"], config: c) == nil)
        c.setAgent("claude-acp", model: "haiku", effort: "low")
        let hint = AssistantClient.hint(clientName: "claude-code", agents: ["claude-acp"], config: c)
        #expect(hint?.contains("`claude-acp` runs on the same subscription as you") == true)
        #expect(hint?.contains("(the user's default: haiku, low)") == true)

        let agent = InstalledAgent(id: "claude-acp", name: "Claude Agent", version: "1", executable: "/x", args: [],
                                   env: [:], installedAt: Date())
        #expect(AgentCatalog.describe(installed: [agent], config: c, checks: [:], clientName: "claude-code")
            .contains("same subscription as you: only with a cheaper model"))
        #expect(!AgentCatalog.describe(installed: [agent], config: c, checks: [:], clientName: "codex-mcp-client")
            .contains("same subscription"))
    }
}

@Suite struct AgentContextTests {
    private func job(_ id: String, _ state: DelegateJobs.State, sensitivity: String? = "public",
                     reportFile: String? = nil) -> DelegateJobs.Job {
        DelegateJobs.Job(id: id, label: "analysis", started: Date(), state: state,
                         details: .init(agent: "fake", sensitivity: sensitivity, reportFile: reportFile))
    }

    @Test func jobsAndFilesBecomeFilesWithTheStrictestSensitivity() throws {
        let dir = try tempDir("ctx")
        let report = dir.appendingPathComponent("report.md")
        try "full report".write(to: report, atomically: true, encoding: .utf8)
        let notes = dir.appendingPathComponent("j1.md")
        try "notes".write(to: notes, atomically: true, encoding: .utf8)
        let jobs = ["j1": job("j1", .done("preview"), sensitivity: "personal", reportFile: report.path),
                    "j2": job("j2", .done("short report"))]
        let c = try AgentContext.resolve(jobIDs: ["j1", "j2"], files: [notes.path], jobs: jobs)
        #expect(c.items.map(\.name) == ["j1.md", "j2.md", "2-j1.md"])   // nazwy bez kolizji
        #expect(c.items.map(\.text) == ["full report", "short report", "notes"])   // z report_file cały plik, nie podgląd
        #expect(c.sensitivity == .personal)
        #expect(c.promptNote.contains(".delegate-context/j2.md: report of job j2 (analysis)"))

        let root = try tempDir("copy")
        try c.write(into: root)
        #expect(try String(contentsOf: root.appendingPathComponent(".delegate-context/2-j1.md"), encoding: .utf8) == "notes")
        #expect(throws: DelegateError.self) { try c.write(into: root) }   // istniejący katalog: nie nadpisujemy
    }

    @Test func unusableSourcesAreRefused() {
        let jobs = ["run": job("run", .running), "bad": job("bad", .failed("boom"))]
        for ids in [["run"], ["bad"], ["missing"]] {
            #expect(throws: DelegateError.self) { try AgentContext.resolve(jobIDs: ids, files: [], jobs: jobs) }
        }
        #expect(throws: DelegateError.self) { try AgentContext.resolve(jobIDs: [], files: ["relative.md"], jobs: [:]) }
        // Zadanie sprzed zapisu wrażliwości liczy się jak personal.
        let old = try? AgentContext.resolve(jobIDs: ["o"], files: [], jobs: ["o": job("o", .done("x"), sensitivity: nil)])
        #expect(old?.sensitivity == .personal)
        #expect(Sensitivity.public < .personal && Sensitivity.personal < .private)
    }
}

@Suite struct AgentPromptTests {
    @Test func writeModeAsksForTheSmallestChangeAndEndsWithTheTask() {
        let cwd = URL(fileURLWithPath: "/tmp/repo")
        let write = AgentRunner.writePrompt(task: "Rename foo to bar", cwd: cwd, branch: "delegate/x", base: "abc")
        #expect(write.contains("Make the smallest change that does what the task asks"))
        #expect(write.hasSuffix("Task:\nRename foo to bar"))   // atrapa agenta czyta ostatnią linię promptu
        // W trybie odczytu nic się nie zmienia, więc reguła tylko by zajmowała miejsce.
        #expect(!AgentRunner.readOnlyPrompt(task: "Map X", cwd: cwd).contains("smallest change"))
    }
}
