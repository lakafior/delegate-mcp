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

        config.setAgent("claude-acp", model: nil, effort: nil)
        #expect(config.agents.isEmpty)

        var withDefaults = try Config.parse(sampleConfigToml)
        withDefaults.setAgent("claude-acp", model: "haiku", effort: "low")
        let text = DelegationGuide(config: withDefaults, agents: ["mistral-vibe", "claude-acp"]) { _ in true }.serverInstructions
        #expect(text.contains("(mistral-vibe; claude-acp: haiku, low)"))
    }

    @Test func instructionsMentionAgentsOnlyWhenInstalled() throws {
        let config = try Config.parse(sampleConfigToml)
        #expect(!DelegationGuide(config: config) { _ in true }.serverInstructions.contains("delegate_agent"))
        let text = DelegationGuide(config: config, agents: ["mistral-vibe"]) { _ in true }.serverInstructions
        #expect(text.contains("`delegate_agent` runs a coding agent (mistral-vibe)"))
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
