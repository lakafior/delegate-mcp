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
        h += includesUncommitted ? " · snapshot: HEAD + uncommitted changes" : " · snapshot: HEAD"
        var out = h + "\n\n" + text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rejected.isEmpty {
            out += "\n\nBlocked (read-only): " + rejected.joined(separator: "; ")
        }
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

    public func run(agent: InstalledAgent, repo: URL, task: String, model: String? = nil, effort: String? = nil,
                    timeout: Duration = .seconds(600), jobID: String = UUID().uuidString) async throws -> AgentReport {
        if useSandbox && !AgentSandbox.isAvailable {
            throw DelegateError(description: "sandbox-exec is missing on this Mac; agents won't run without a sandbox.")
        }
        let fm = FileManager.default
        let jobDir = workRoot.appendingPathComponent(jobID, isDirectory: true)
        let tmp = jobDir.appendingPathComponent("tmp", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let snapshot = try RepoSnapshot.create(repo: repo, at: jobDir.appendingPathComponent("repo", isDirectory: true))
        defer { snapshot.remove() }

        let homeDir = userHome
        let state = AgentSandbox.stateDirectories(forAgent: agent.id, kind: agent.kind, home: homeDir)
        // Katalogi (bez kropki w nazwie pliku, jak `.claude.json`) zakładamy, żeby agent miał gdzie pisać.
        for dir in state where dir.pathExtension.isEmpty { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        var executable = URL(fileURLWithPath: agent.executable)
        var arguments = agent.args
        if useSandbox {
            var sandbox = AgentSandbox(home: homeDir, writable: state + [tmp], readOnly: [snapshot.path],
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
                await Self.readOnlyPolicy(method, params, collector, sandboxed: useSandbox)
            },
            onNotification: { method, params in
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
            for mode in Self.readOnlyModes where (try? await conn.setOption(session, "mode", mode)) == true {
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

            let prompt = Self.readOnlyPrompt(task: task, cwd: snapshot.path, includesUncommitted: snapshot.includesUncommitted)
            let result: JSONValue
            do {
                result = try await conn.request("session/prompt", [
                    "sessionId": .string(session.id), "prompt": [["type": "text", "text": .string(prompt)]],
                ], timeout: timeout)
            } catch ACPConnection.ConnectionError.timeout {
                try? await conn.notify("session/cancel", ["sessionId": .string(session.id)])
                await conn.close()
                let partial = await collector.text
                throw DelegateError(description: "\(agent.name) didn't finish in \(timeout). Partial report:\n\(partial)")
            }
            await conn.close()
            // Po udanym zadaniu katalog (profil, log agenta) nie jest potrzebny; po błędzie zostaje do diagnozy.
            defer { try? fm.removeItem(at: jobDir) }
            var report = await collector.report(agent: hello.name ?? agent.name, model: usedModel, effort: usedEffort, mode: usedMode,
                                          seconds: Date().timeIntervalSince(started),
                                          stopReason: result["stopReason"]?.stringValue,
                                          includesUncommitted: snapshot.includesUncommitted)
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

    /// Rodzaje narzędzi ACP, które zmieniają pliki: zawsze odmowa.
    static let mutatingKinds: Set<String> = ["edit", "delete", "move"]

    /// Tryb tylko do odczytu. W piaskownicy przepuszczamy polecenia i odczyty (zapisu i tak nie zrobią,
    /// a odmowa zwykłego `grep` tylko psuje analizę), odmawiamy zmian plików. Bez piaskownicy odmawiamy wszystkiego.
    /// Operacji klienta (`fs/*`, `terminal/*`) nie ogłaszamy, więc ich też odmawiamy.
    static func readOnlyPolicy(_ method: String, _ params: JSONValue, _ collector: AgentCollector,
                               sandboxed: Bool) async -> Result<JSONValue, ACPConnection.RemoteError> {
        guard method == "session/request_permission" else { return .failure(.methodNotFound(method)) }
        let options = params["options"]?.arrayValue ?? []
        let toolCall = params["toolCall"] ?? .null
        let kind = await collector.kind(toolCall)
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
