import Foundation

/// Wynik pracy agenta na kopii repo.
public struct AgentReport: Sendable {
    public struct ToolCall: Sendable, Equatable {
        public var title: String
        public var kind: String?
        public var status: String?
    }

    public var agent: String
    public var model: String?
    public var effort: String?
    /// Natywny tryb tylko do odczytu, w którym działał agent (np. `plan`); `nil` = tylko piaskownica.
    public var mode: String?
    public var text: String
    public var toolCalls: [ToolCall]
    /// Odrzucone prośby o zgodę (próby zapisu albo poleceń, na które agent pytał).
    public var rejected: [String]
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var seconds: Double
    public var stopReason: String?
    public var includesUncommitted: Bool
    /// Tryb zapisu: gałąź ze zmianami agenta (`nil` w trybie analizy).
    public var branch: RepoSnapshot.BranchResult?
    public var write = false
    /// Tryb zapisu: niezacommitowane zmiany użytkownika nie weszły do gałęzi.
    public var uncommittedLeftOut = false
    /// Tryb zapisu z `check`: wynik po ostatniej rundzie poprawek.
    public var check: CheckResult?
    /// Z `check` raport jest krótki (senior patrzy na wynik testów i `--stat`): tyle znaków podsumowania agenta.
    static let briefSummaryCharacters = 600

    /// Tekst dla Claude'a: nagłówek jak przy `delegate`, raport, na końcu skrót tego, co agent robił.
    public var formatted: String {
        var h = "[delegate_agent] agent: \(agent)"
        if let model { h += " · model: \(model)" }
        if let effort { h += " · effort: \(effort)" }
        if let mode { h += " · mode: \(mode)" }
        h += " · tokens: \(inputTokens.map(String.init) ?? "?") in / \(outputTokens.map(String.init) ?? "?") out"
        h += String(format: " · %.0f s", seconds)
        h += " · steps: \(toolCalls.count)"
        if let stopReason, stopReason != "end_turn" { h += " · stopped: \(stopReason)" }
        if write {
            h += " · write mode"
        } else {
            h += includesUncommitted ? " · snapshot: HEAD + uncommitted changes" : " · snapshot: HEAD"
        }
        var summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let check {
            if summary.count > Self.briefSummaryCharacters {
                summary = String(summary.suffix(Self.briefSummaryCharacters)).drop { $0 != " " && $0 != "\n" }
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                summary = "…" + summary
            }
            summary = check.line + (check.passed ? "" : ":\n```\n\(check.output)\n```") + "\n\nAgent's summary: " + summary
        }
        var out = h + "\n\n" + summary
        if !rejected.isEmpty {
            out += "\n\nBlocked\(write ? "" : " (read-only)"): " + rejected.joined(separator: "; ")
        }
        if write { out += "\n\n" + Self.branchSection(branch, uncommittedLeftOut: uncommittedLeftOut) }
        return out
    }

    /// Co dyrygent ma zrobić z gałęzią: przejrzeć, scalić albo wyrzucić.
    static func branchSection(_ branch: RepoSnapshot.BranchResult?, uncommittedLeftOut: Bool) -> String {
        guard let b = branch, b.commits > 0 else {
            return "No changes were made; the branch was removed."
        }
        var out = "Changes are on branch `\(b.branch)` (from \(b.base)): \(b.summary)."
        if uncommittedLeftOut {
            out += " The user's uncommitted changes were not part of the agent's starting point."
        }
        out += "\nReview: `git diff \(b.base)...\(b.branch)` · Merge: `git merge --squash \(b.branch)` · Discard: `git branch -D \(b.branch)`"
        if !b.diffStat.isEmpty { out += "\n```\n\(b.diffStat)\n```" }
        return out
    }
}

/// Gdzie agent wysyła dane (kod z repo idzie do jego dostawcy) i czy zadanie może do niego trafić.
public enum AgentRegions {
    /// Region z ustawień agenta, a bez nich z wbudowanej tabeli.
    public static func region(for agentID: String, config: Config) -> PrivacyRegion {
        config.agentSettings(agentID)?.privacy ?? region(for: agentID)
    }

    /// Region z wbudowanej tabeli (znani dostawcy agentów).
    public static func region(for agentID: String) -> PrivacyRegion {
        switch agentID {
        case "mistral-vibe": .eu
        case "gemini", "antigravity-acp", "claude-acp", "codex-acp", "opencode", "opencode-v2", "goose", "amp-acp", "cursor", "github-copilot-cli", "junie", "devin": .us
        case "kimi", "qwen-code", "glm-acp-agent", "minimax-code": .cn
        default: .other
        }
    }

    /// Czy zadanie może trafić do agenta: włączony, reguła repo, wrażliwość danych. `nil` = może, inaczej powód.
    public static func refusal(agentID: String, sensitivity: Sensitivity, config: Config, repo: URL? = nil) -> String? {
        if config.agentSettings(agentID)?.isEnabled == false {
            return "\(agentID) is turned off in Delegate"
        }
        if let repo, let rule = config.repoRule(for: repo), !rule.agents.contains(agentID) {
            let allowed = rule.agents.isEmpty ? "no agents" : "only " + rule.agents.joined(separator: ", ")
            return "the user allows \(allowed) for \(rule.path)"
        }
        let region = region(for: agentID, config: config)
        switch sensitivity {
        case .private:
            return "private data stays on this Mac, and \(agentID) sends the repository to its cloud model"
        case .personal where !config.personalRegions.contains(region):
            return "personal or work data doesn't go to region \(region.rawValue) (\(agentID))"
        default:
            return nil
        }
    }
}

/// Wybór agenta, gdy dyrygent go nie podał: pierwszy dozwolony wg priorytetu (`Config.prioritizedAgents`).
public enum AgentChoice {
    public struct Result: Sendable, Equatable {
        public var agent: String?
        /// Agenci przed wybranym (albo wszyscy, gdy nikt nie pasuje) z powodem pominięcia.
        public var skipped: [RoutingExclusion]
    }

    /// `agents`: zainstalowani i włączeni, już w kolejności priorytetu. `paused`: aktywne przerwy (`ModelCooldowns`,
    /// klucze `agent:<id>`).
    public static func pick(from agents: [String], sensitivity: Sensitivity, config: Config, repo: URL?,
                            checks: [String: AgentCheckRecord], clientName: String?,
                            paused: [String: ModelCooldown] = [:]) -> Result {
        let shared = AssistantClient.sameSubscriptionAgent(clientName: clientName)
        var skipped: [RoutingExclusion] = []
        for id in agents {
            if let why = AgentRegions.refusal(agentID: id, sensitivity: sensitivity, config: config, repo: repo) {
                skipped.append(RoutingExclusion(ref: id, reason: why, kind: .region))
            } else if let pause = paused[AgentPause.key(id)] {
                let until = pause.until.formatted(date: .omitted, time: .shortened)
                skipped.append(RoutingExclusion(ref: id, reason: "\(RoutingExclusion.pausePrefix) \(until): \(pause.reason)", kind: .pause))
            } else if checks[id]?.status == "needsSignIn" {
                skipped.append(RoutingExclusion(ref: id, reason: "not signed in (the user signs in in the Delegate app)", kind: .unavailable))
            } else if id == shared, config.agentSettings(id)?.model == nil {
                // Bez tańszego modelu w ustawieniach to ten sam model co dyrygent: nie wybieramy go sami.
                skipped.append(RoutingExclusion(ref: id, reason: "same subscription as you and no cheaper default model set", kind: .unavailable))
            } else {
                return Result(agent: id, skipped: skipped)
            }
        }
        return Result(agent: nil, skipped: skipped)
    }

    /// Odmowa, gdy nikt nie pasuje: powody i co zrobić (jak `RoutingPlan.refusalAdvice`).
    public static func refusal(_ result: Result) -> String {
        var out = "No agent can take this task."
        if !result.skipped.isEmpty {
            out += "\nSkipped:\n" + result.skipped.map { "- \($0.ref): \($0.reason)" }.joined(separator: "\n")
        }
        out += "\nWhat to do: name an agent with `agent` if one of the reasons doesn't apply (e.g. same subscription with a cheaper `model`), lower `sensitivity` only if the code really allows it, or do the task yourself."
        return out
    }
}

/// Uruchamia agenta ACP na kopii repo w piaskownicy, w trybie tylko do odczytu, i zbiera raport.
public struct AgentRunner: Sendable {
    let home: DelegateHome
    /// Katalogi zadań (kopie repo, katalogi tymczasowe, logi). Poza katalogiem `Delegate`, w Caches.
    let workRoot: URL
    let useSandbox: Bool
    /// Katalog domowy, w którym agent trzyma stan (logowanie); w testach tymczasowy.
    let userHome: URL

    public init(home: DelegateHome, workRoot: URL? = nil, useSandbox: Bool = true,
                userHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.userHome = userHome
        self.home = home
        self.workRoot = workRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mar.delegate/agent-jobs", isDirectory: true)
        self.useSandbox = useSandbox
    }

    /// Runda poprawki po nieudanym `check`.
    static func fixPrompt(check: String, result: CheckResult) -> String {
        """
        The acceptance check `\(check)` failed (exit \(result.exitCode)):
        ```
        \(result.output)
        ```
        Fix the code so that it passes. Don't weaken the check or the tests to make it pass unless they are wrong; \
        if they are, say why. Reply with a short summary of what you changed.
        """
    }

    /// Zasady doklejane przed zadaniem. Piaskownica i tak blokuje zapis; to oszczędza agentowi prób.
    static func readOnlyPrompt(task: String, cwd: URL, includesUncommitted: Bool = false) -> String {
        // `git stash create` robi z niezacommitowanych zmian dwa techniczne commity; bez tej uwagi agent bierze je za historię.
        let snapshotNote = includesUncommitted
            ? " The top commit (\"WIP on …\", with \"index on …\" below it) is a snapshot of the user's uncommitted changes, not real history; real commits start below them."
            : ""
        return """
        You are working in a read-only copy of a git repository at \(cwd.path). Do not modify, create or delete \
        any files: writes are blocked by the sandbox and will fail. Use read-only commands (ls, cat, grep, git log, \
        git diff) only. Answer with a concise Markdown report and cite file:line for concrete claims.\(snapshotNote)

        Task:
        \(task)
        """
    }

    /// Tryb zapisu: agent zmienia pliki na gałęzi `delegate/…`; może budować i testować.
    static func writePrompt(task: String, cwd: URL, branch: String, base: String) -> String {
        """
        You are working in a git worktree of the user's repository at \(cwd.path), on branch \(branch) created from \
        \(base.prefix(10)) (it may already contain earlier work on this task: check `git log` first). Make the changes \
        the task asks for by editing files in this directory. You may run builds \
        and tests; network access is available for package managers. You already run inside a sandbox, so tools that \
        start their own sandbox must have it disabled (Swift packages: `swift build --disable-sandbox`, \
        `swift test --disable-sandbox`). Do not commit, push, switch branches or touch files outside this directory: \
        your changes are committed to the branch for the user when you finish. End with a short Markdown summary: \
        what you changed (file by file), what you ran to check it and the result, and anything left undone.

        Make the smallest change that does what the task asks, in the style of the surrounding code. No new \
        abstractions, options, dependencies or files the task doesn't need, no refactoring or reformatting of code \
        you don't have to touch, no extra features "while you're at it". Add tests only if the task asks for them or \
        the change can't be checked otherwise. If the task seems to need more than that, do the minimal part and say \
        what else you'd change in the summary.

        Task:
        \(task)
        """
    }

    /// Tyle ciszy (bez `session/update` i próśb o zgodę) znaczy, że agent się zawiesił. W trybie zapisu dłużej:
    /// pierwsze `swift build` albo testy potrafią trwać minuty bez żadnej aktualizacji.
    public static func idleLimit(write: Bool) -> Duration { write ? .seconds(360) : .seconds(180) }

    public func run(agent: InstalledAgent, repo: URL, task: String, model: String? = nil, effort: String? = nil,
                    write: Bool = false, branchFrom: String? = nil, timeout: Duration = .seconds(600),
                    idleLimit: Duration? = nil, check: String? = nil, context: AgentContext? = nil,
                    jobID: String = UUID().uuidString) async throws -> AgentReport {
        if useSandbox && !AgentSandbox.isAvailable {
            throw DelegateError(description: "sandbox-exec is missing on this Mac; agents won't run without a sandbox.")
        }
        let fm = FileManager.default
        let jobDir = workRoot.appendingPathComponent(jobID, isDirectory: true)
        let tmp = jobDir.appendingPathComponent("tmp", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let copyPath = jobDir.appendingPathComponent("repo", isDirectory: true)
        let snapshot = write
            ? try RepoSnapshot.createBranch(repo: repo, at: copyPath,
                                            branch: RepoSnapshot.branchName(agent: agent.id, task: task, id: jobID),
                                            from: branchFrom)
            : try RepoSnapshot.create(repo: repo, at: copyPath)
        // Gałąź ze zmianami zostaje w repo użytkownika; pustą (albo przy błędzie przed pracą) usuwamy.
        var keepBranch = false
        defer { snapshot.remove(deleteBranch: write && !keepBranch) }
        if let context, !context.isEmpty { try context.write(into: snapshot.path) }
        // Kontekst nie trafia do commitu agenta.
        func finishBranch(_ message: String) -> RepoSnapshot.BranchResult? {
            AgentContext.remove(from: snapshot.path)
            return snapshot.finishBranch(message: message, author: "Delegate (\(agent.name))")
        }

        let homeDir = userHome
        let state = AgentSandbox.stateDirectories(forAgent: agent.id, kind: agent.kind, home: homeDir)
        // Katalogi (bez kropki w nazwie pliku, jak `.claude.json`) zakładamy, żeby agent miał gdzie pisać.
        for dir in state where dir.pathExtension.isEmpty { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        var executable = URL(fileURLWithPath: agent.executable)
        var arguments = agent.args
        if useSandbox {
            let writable = write
                ? state + [tmp, snapshot.path] + AgentSandbox.gitWriteDirectories(snapshot) + AgentSandbox.buildDirectories(home: homeDir)
                : state + [tmp]
            var sandbox = AgentSandbox(home: homeDir, writable: writable, readOnly: write ? [] : [snapshot.path],
                                       hidden: AgentSandbox.defaultHidden(home: homeDir, delegateHome: home) + [snapshot.repo])
            sandbox.readableExceptions = [snapshot.gitDirectory]
            sandbox.metadataExceptions = [snapshot.repo]
            let profileURL = jobDir.appendingPathComponent("sandbox.sb")
            try sandbox.profile().write(to: profileURL, atomically: true, encoding: .utf8)
            (executable, arguments) = sandbox.command(profileURL: profileURL, executable: executable, arguments: arguments)
        }

        let collector = AgentCollector()
        let started = Date()
        let conn = try ACPConnection.launch(
            executable: executable, arguments: arguments,
            environment: agent.env.merging(AgentSandbox.temporaryEnvironment(tmp)) { _, new in new },
            workingDirectory: snapshot.path,
            stderrLog: jobDir.appendingPathComponent("agent.log"),
            onRequest: { [useSandbox] method, params in
                await collector.touch()
                return await Self.permissionPolicy(method, params, collector, sandboxed: useSandbox, write: write)
            },
            onNotification: { method, params in
                await collector.touch()
                if method == "session/update" { await collector.update(params["update"] ?? .null) }
            })

        do {
            let hello = try await conn.initialize()
            let session: ACPSession
            var usedMode: String?
            do {
                session = try await conn.newSession(cwd: snapshot.path)
            } catch let e as ACPConnection.RemoteError where e.isAuthRequired {
                let how = hello.authMethods.first.map { " (\($0.name))" } ?? ""
                throw DelegateError(description: "\(agent.name) isn't signed in\(how). Sign in to the agent first, then retry.")
            }
            // Natywny tryb tylko do odczytu, jeśli agent go ma (Claude Agent: `plan`, Vibe: `ask`); piaskownica i tak
            // blokuje zapis, to druga warstwa. W `plan` Claude dalej używa powłoki (sprawdzone), więc analiza nie traci.
            usedMode = nil
            for mode in (write ? Self.editModes : Self.readOnlyModes) where (try? await conn.setOption(session, "mode", mode)) == true {
                usedMode = mode
                break
            }
            var usedModel: String?
            if let model, !model.isEmpty {
                guard try await conn.setOption(session, "model", model) else {
                    let known = session.models.isEmpty ? "it doesn't offer a model choice" : "available: " + session.models.joined(separator: ", ")
                    throw DelegateError(description: "\(agent.name) has no model \"\(model)\"; \(known).")
                }
                usedModel = model
            } else {
                usedModel = session.modelOption?.current
            }
            var usedEffort: String?
            if let effort, !effort.isEmpty {
                guard let option = session.effortOption else {
                    throw DelegateError(description: "\(agent.name) doesn't offer an effort setting.")
                }
                guard try await conn.setOption(session, option.id, effort) else {
                    throw DelegateError(description: "\(agent.name) has no effort \"\(effort)\"; available: \(option.values.joined(separator: ", ")).")
                }
                usedEffort = effort
            } else {
                usedEffort = session.effortOption?.current
            }

            let fullTask = context.flatMap { $0.isEmpty ? nil : $0.promptNote + "\n\n" + task } ?? task
            let prompt = write
                ? Self.writePrompt(task: fullTask, cwd: snapshot.path, branch: snapshot.branch ?? "", base: snapshot.baseCommit ?? "")
                : Self.readOnlyPrompt(task: fullTask, cwd: snapshot.path, includesUncommitted: snapshot.includesUncommitted)
            let commitMessage = "\(agent.name): \(DelegateJobs.shortLabel(task))\n\nDelegated task:\n\(task)"
            let result: JSONValue
            let idle = idleLimit ?? Self.idleLimit(write: write)
            await collector.touch()
            // Zawieszony agent (np. czeka na własne zadanie w tle) nie zjada całego limitu: po ciszy kończymy.
            let watchdog = Task { [collector] in
                let step = min(Duration.seconds(10), idle / 4)
                while !Task.isCancelled {
                    try? await Task.sleep(for: step)
                    let quiet = await collector.quietSeconds
                    if quiet >= Double(idle.components.seconds) {
                        await conn.abort(.idle(seconds: Int(quiet)))
                        return
                    }
                }
            }
            defer { watchdog.cancel() }
            do {
                result = try await conn.request("session/prompt", [
                    "sessionId": .string(session.id), "prompt": [["type": "text", "text": .string(prompt)]],
                ], timeout: timeout)
            } catch let stop as ACPConnection.ConnectionError where stop.isTimeLimit {
                try? await conn.notify("session/cancel", ["sessionId": .string(session.id)])
                await conn.close()
                let partial = await collector.text
                var note = ""
                var kept: String?
                if write, let b = finishBranch(commitMessage + "\n\n(unfinished: timed out)"), b.commits > 0 {
                    keepBranch = true
                    kept = b.branch
                    note = "\nUnfinished changes are on branch `\(b.branch)` (\(b.summary)); review before using them."
                }
                let what = if case .idle(let s) = stop { "stopped responding (nothing for \(s) s)" } else { "didn't finish in \(timeout)" }
                throw DelegateError(description: "\(agent.name) \(what).\(note) Partial report:\n\(partial)",
                                    branch: kept)
            }
            // Kryterium akceptacji: jak senior, który odsyła pracę juniorowi, aż testy przejdą. Poprawki w tej samej
            // sesji (agent pamięta, co zrobił); w czasie polecenia watchdog ciszy śpi.
            var checkResult: CheckResult?
            if write, let check = check?.trimmingCharacters(in: .whitespacesAndNewlines), !check.isEmpty {
                let runner = CheckRunner(home: home, userHome: userHome, useSandbox: useSandbox)
                let writable = AgentSandbox.gitWriteDirectories(snapshot)
                await collector.setWatching(false)
                var outcome = await runner.run(check, in: snapshot.path, writable: writable, network: true)
                while !outcome.passed && outcome.fixes < DelegateRequest.maxFixRounds {
                    await collector.setWatching(true)
                    do {
                        _ = try await conn.request("session/prompt", [
                            "sessionId": .string(session.id),
                            "prompt": [["type": "text", "text": .string(Self.fixPrompt(check: check, result: outcome))]],
                        ], timeout: timeout)
                    } catch {
                        break   // limit czasu albo cisza w poprawce: zostaje ostatni wynik, praca na gałęzi
                    }
                    await collector.setWatching(false)
                    let fixes = outcome.fixes + 1
                    outcome = await runner.run(check, in: snapshot.path, writable: writable, network: true)
                    outcome.fixes = fixes
                }
                checkResult = outcome
            }
            await conn.close()
            var branch: RepoSnapshot.BranchResult?
            if write {
                branch = finishBranch(commitMessage)
                keepBranch = (branch?.commits ?? 0) > 0
            }
            // Po udanym zadaniu katalog (profil, log agenta) nie jest potrzebny; po błędzie zostaje do diagnozy.
            defer { try? fm.removeItem(at: jobDir) }
            var report = await collector.report(agent: hello.name ?? agent.name, model: usedModel, effort: usedEffort, mode: usedMode,
                                          seconds: Date().timeIntervalSince(started),
                                          stopReason: result["stopReason"]?.stringValue,
                                          includesUncommitted: snapshot.includesUncommitted)
            report.write = write
            report.check = checkResult
            report.branch = branch
            report.uncommittedLeftOut = snapshot.uncommittedLeftOut
            // Kopia repo znika po zadaniu: ścieżki do niej (np. linki `file://` w raporcie) zamieniamy na oryginał.
            for copy in Set([Self.realPath(snapshot.path.path), snapshot.path.path]).sorted(by: { $0.count > $1.count }) {
                report.text = report.text.replacingOccurrences(of: copy, with: snapshot.repo.path)
            }
            return report
        } catch {
            await conn.close()
            throw error
        }
    }

    /// Ścieżka po rozwinięciu linków tak, jak widzi ją proces (`/var` → `/private/var`); Foundation obcina `/private`.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Tryby sesji, które ograniczają agenta do czytania, w kolejności preferencji.
    static let readOnlyModes = ["plan", "ask", "read-only", "readonly"]
    /// Tryby sesji dla zapisu: edycje bez pytania (resztę i tak zatwierdzamy, granice trzyma piaskownica).
    static let editModes = ["acceptEdits", "accept-edits"]

    /// Rodzaje narzędzi ACP, które zmieniają pliki: zawsze odmowa.
    static let mutatingKinds: Set<String> = ["edit", "delete", "move"]

    /// Zgody dla agenta. Tryb analizy w piaskownicy: polecenia i odczyty tak (zapisu i tak nie zrobią, a odmowa
    /// zwykłego `grep` psuje analizę), zmiany plików nie. Tryb zapisu w piaskownicy: wszystko tak — piaskownica
    /// ogranicza zapis do worktree, cache narzędzi i gałęzi `delegate/*`. Bez piaskownicy: wszystko nie.
    /// Operacji klienta (`fs/*`, `terminal/*`) nie ogłaszamy, więc ich też odmawiamy.
    static func permissionPolicy(_ method: String, _ params: JSONValue, _ collector: AgentCollector,
                                 sandboxed: Bool, write: Bool = false) async -> Result<JSONValue, ACPConnection.RemoteError> {
        guard method == "session/request_permission" else { return .failure(.methodNotFound(method)) }
        let options = params["options"]?.arrayValue ?? []
        let toolCall = params["toolCall"] ?? .null
        let kind = await collector.kind(toolCall)
        if sandboxed, write,
           let allow = options.first(where: { $0["kind"]?.stringValue == "allow_once" })
            ?? options.first(where: { $0["kind"]?.stringValue?.hasPrefix("allow") == true }),
           let id = allow["optionId"] {
            return .success(["outcome": ["outcome": "selected", "optionId": id]])
        }
        if sandboxed, let kind, !mutatingKinds.contains(kind),
           let allow = options.first(where: { $0["kind"]?.stringValue == "allow_once" }), let id = allow["optionId"] {
            return .success(["outcome": ["outcome": "selected", "optionId": id]])
        }
        let what = await collector.describe(toolCall)
        await collector.reject(what)
        if let reject = options.first(where: { $0["kind"]?.stringValue?.hasPrefix("reject") == true }),
           let id = reject["optionId"] {
            return .success(["outcome": ["outcome": "selected", "optionId": id]])
        }
        return .success(["outcome": ["outcome": "cancelled"]])
    }
}

/// Zbiera powiadomienia `session/update` w raport.
actor AgentCollector {
    private(set) var text = ""
    private var lastActivity = Date()
    private var watching = true
    /// Sekundy od ostatniej wiadomości od agenta (watchdog zawieszenia); 0, gdy agent czeka na nas (np. `check`).
    var quietSeconds: Double { watching ? Date().timeIntervalSince(lastActivity) : 0 }

    func touch() { lastActivity = Date() }

    func setWatching(_ on: Bool) {
        watching = on
        lastActivity = Date()
    }
    private var calls: [String: AgentReport.ToolCall] = [:]
    private var order: [String] = []
    private var rejected: [String] = []
    private var inputTokens: Int?
    private var outputTokens: Int?

    func update(_ u: JSONValue) {
        switch u["sessionUpdate"]?.stringValue {
        case "agent_message_chunk":
            if let t = u["content"]?["text"]?.stringValue { text += t }
        case "tool_call", "tool_call_update":
            guard let id = u["toolCallId"]?.stringValue else { return }
            if calls[id] == nil { order.append(id); calls[id] = .init(title: id) }
            if let title = u["title"]?.stringValue { calls[id]?.title = title }
            if let kind = u["kind"]?.stringValue { calls[id]?.kind = kind }
            if let status = u["status"]?.stringValue { calls[id]?.status = status }
        case "usage_update":
            // Vibe: `_meta.promptTokens` / `completionTokens`; to rozszerzenie, nie część ACP v1.
            if let p = u["_meta"]?["promptTokens"]?.intValue { inputTokens = p }
            if let c = u["_meta"]?["completionTokens"]?.intValue { outputTokens = c }
        default:
            break
        }
    }

    func describe(_ toolCall: JSONValue) -> String {
        if let t = toolCall["title"]?.stringValue { return t }
        if let id = toolCall["toolCallId"]?.stringValue, let t = calls[id]?.title, t != id { return t }
        return toolCall["kind"]?.stringValue ?? "tool call"
    }

    func reject(_ what: String) { rejected.append(what) }

    /// Rodzaj narzędzia z prośby o zgodę albo z wcześniejszego `tool_call` o tym ID.
    func kind(_ toolCall: JSONValue) -> String? {
        if let k = toolCall["kind"]?.stringValue { return k }
        return toolCall["toolCallId"]?.stringValue.flatMap { calls[$0]?.kind }
    }

    func report(agent: String, model: String?, effort: String?, mode: String?, seconds: Double, stopReason: String?, includesUncommitted: Bool) -> AgentReport {
        AgentReport(agent: agent, model: model, effort: effort, mode: mode, text: text, toolCalls: order.compactMap { calls[$0] },
                    rejected: rejected, inputTokens: inputTokens, outputTokens: outputTokens,
                    seconds: seconds, stopReason: stopReason, includesUncommitted: includesUncommitted)
    }
}
