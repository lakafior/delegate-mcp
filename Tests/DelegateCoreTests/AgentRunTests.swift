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
                                            repo: repo, task: "Check things", model: "m2")
        let text = report.text
        #expect(text.contains("read:uncommitted"))   // kopia ma niezacommitowane zmiany
        #expect(text.contains("write:blocked"))      // kopia repo tylko do odczytu
        #expect(text.contains("env:no"))             // pliki nieśledzone nie trafiają do kopii
        #expect(text.contains("secret:blocked"))     // oryginalne repo niewidoczne
        #expect(text.contains("tmp:ok"))             // katalog tymczasowy zadania zapisywalny
        #expect(text.contains("model:m2"))
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
        #expect(report.formatted.hasPrefix("[delegate_agent] agent: Fake Agent · model: m2 · tokens: 100 in / 7 out"))
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
