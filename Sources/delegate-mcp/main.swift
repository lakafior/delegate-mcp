import DelegateCore
import Foundation
import MCP

/// Jedyne źródło wersji: `build-app.sh` wpisuje ją do Info.plist, a workflow wydania sprawdza, czy zgadza się z tagiem.
let version = "0.1.0"
let home = DelegateHome.resolve()
let args = CommandLine.arguments.dropFirst()

// Tryby CLI. W trybie serwera stdout należy do protokołu, więc nic tam nie drukujemy.
if args.contains("--version") {
    print("delegate-mcp \(version)")
    exit(0)
}
if args.contains("--print-config-path") {
    print(home.configURL.path)
    exit(0)
}
if args.contains("--init") {
    do {
        let created = try home.writeDefaultConfig()
        print(created ? "Created \(home.configURL.path)" : "Already exists: \(home.configURL.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
        exit(1)
    }
}
// Dla diagnostyki: czy TEN plik binarny (czyli serwer uruchamiany przez Claude'a) odczyta klucze
// bez okna z hasłem. Wypisuje JSON `{"<api_key_env>": "readable|missing|needsApproval"}`.
if args.contains("--check-keys") {
    let env = EnvSecretStore(dotEnv: home.envURL)
    let keychain = KeychainSecretStore()
    var result: [String: String] = [:]
    for p in (try? home.loadConfig())?.providers ?? [] where p.needsKey {
        result[p.apiKeyEnv] = env.hasSecret(for: p.apiKeyEnv)
            ? KeychainSecretStore.Access.readable.rawValue
            : keychain.accessWithoutPrompt(for: p.apiKeyEnv).rawValue
    }
    let data = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data("{}".utf8)
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}
if args.contains("doctor") || args.contains("--doctor") {
    let doctor = DelegateDoctor(home: home, helper: Bundle.main.executableURL)
    let report = await doctor.diagnose()
    print(report.terminalOutput())
    exit(report.allOk ? 0 : 1)
}
// Agenci ACP z terminala (zanim apka dostanie swoją zakładkę): `--agents`, `--install-agent <id>`.
if args.contains("--agents") || args.contains("--install-agent") {
    let installer = AgentInstaller(directory: home.agentsURL)
    if let i = args.firstIndex(of: "--install-agent") {
        guard let id = args.dropFirst(i - args.startIndex + 1).first else {
            FileHandle.standardError.write(Data("Usage: delegate-mcp --install-agent <id>\n".utf8))
            exit(2)
        }
        guard let registry = await ACPRegistryStore(cacheURL: home.agentRegistryURL).load(),
              let agent = registry.agent(id) else {
            FileHandle.standardError.write(Data("No agent \"\(id)\" in the ACP registry.\n".utf8))
            exit(1)
        }
        do {
            let installed = try await installer.install(agent, allowUnverified: args.contains("--allow-unverified"))
            print("Installed \(installed.name) \(installed.version) (verified by \(installed.verifiedBy ?? "?")\(installed.signer.map { ": \($0)" } ?? "")): \(installed.executable)")
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            exit(1)
        }
    }
    for a in installer.installed() { print("\(a.id)\t\(a.version)\t\(a.executable)") }
    exit(0)
}

let service = DelegateService(home: home)
let jobStore = JobStore(directory: home.jobsURL)
jobStore.purge()
let jobs = DelegateJobs(service: service, store: jobStore)
let agentInstaller = AgentInstaller(directory: home.agentsURL)
let agentRunner = AgentRunner(home: home)
let agentSlots = AgentSlots(limit: ((try? home.loadConfig()) ?? Config()).maxParallelAgents ?? Config.defaultMaxParallelAgents)
let usageLog = UsageLog(url: home.usageURL)

/// Nazwa klienta MCP (dyrygenta) z `initialize`; instrukcje serwera są stałe, więc podpowiedź o agencie na tej samej
/// subskrypcji trafia do opisu `delegate_agent` i do `list_models`, które klient pobiera po `initialize`.
actor ClientState {
    var name: String?
    func set(_ name: String) { self.name = name }
}
let clientState = ClientState()

func schema(_ properties: [String: Value], required: [String] = []) -> Value {
    var obj: [String: Value] = ["type": .string("object"), "properties": .object(properties)]
    if !required.isEmpty { obj["required"] = .array(required.map { .string($0) }) }
    return .object(obj)
}

func reply(_ text: String) -> Tool.Content {
    .text(text: text, annotations: nil, _meta: nil)
}

func prop(_ type: String, _ description: String) -> Value {
    .object(["type": .string(type), "description": .string(description)])
}

/// Config czytany przy każdym wywołaniu; przy błędzie pusty, żeby serwer i tak wystartował.
/// Agenci, których dyrygent może użyć: zainstalowani i niewyłączeni w apce. Liczone przy każdym wywołaniu,
/// więc nowy agent działa bez restartu klienta (który dostaje też `tools/list_changed`).
func usableAgents(_ config: Config) -> [InstalledAgent] {
    agentInstaller.installed().filter { config.agentSettings($0.id)?.isEnabled != false }
}

func currentGuide() -> DelegationGuide {
    let config = (try? service.currentConfig()) ?? Config()
    return service.guide(config: config, agents: usableAgents(config).map(\.id))
}

/// Lista narzędzi budowana na żądanie: opis `delegate` zawiera aktualne modele i tagi.
func makeTools(_ guide: DelegationGuide, clientName: String? = nil) -> [Tool] {
    baseTools(guide) + (guide.agents.isEmpty ? [] : [agentTool(guide, clientName: clientName)])
}

/// `delegate_agent` tylko, gdy jest zainstalowany agent: bez niego narzędzie tylko zabierałoby miejsce.
func agentTool(_ guide: DelegationGuide, clientName: String?) -> Tool {
    let hint = AssistantClient.hint(clientName: clientName, agents: guide.agents,
                                    config: (try? service.currentConfig()) ?? Config()).map { " " + $0 } ?? ""
    return Tool(
        name: "delegate_agent",
        description: "Run a coding agent on a git repo in the background, in a sandbox. mode=read (default): read-only snapshot (HEAD + uncommitted changes), returns a report. mode=write: the agent edits files, builds and tests on a new branch delegate/… from HEAD; you get the branch, diff stat and summary, then review (git diff) and merge or delete it. Returns a job ID; collect with delegate_result (jobs take minutes)." + hint,
        inputSchema: schema([
            "agent": prop("string", "Agent ID: \(guide.agents.joined(separator: ", ")). Models and effort per agent: list_models."),
            "repo": prop("string", "Absolute path inside the git repository."),
            "task": prop("string", "What to find out; the agent sees the repo, not this conversation. Say what the report should contain."),
            "model": prop("string", "Agent's model option; default from the user's settings, else the agent's own (an error lists the valid ones)."),
            "effort": prop("string", "Agent's effort/thinking level (e.g. low); default from the user's settings."),
            "sensitivity": .object([
                "type": .string("string"),
                "enum": .array(Sensitivity.allCases.map { .string($0.rawValue) }),
                "description": .string("The whole repo is sent to the agent's cloud model; personal = work or personal code."),
            ]),
            "report_file": prop("string", "Absolute path; write the report there and return only the header and a preview."),
            "branch_from": prop("string", "Write mode: branch or commit to start from instead of HEAD, e.g. a previous delegate/… branch for a follow-up round."),
            "mode": .object([
                "type": .string("string"), "enum": .array([.string("read"), .string("write")]),
                "description": .string("read (default) or write (changes on a new branch; give a precise, self-contained task and the checks to run)."),
            ]),
        ], required: ["agent", "repo", "task"])
    )
}

func baseTools(_ guide: DelegationGuide) -> [Tool] { [
    Tool(
        name: "list_models",
        description: "Full model list with tags, costs, key status. Only if the catalog in the server instructions isn't enough.",
        inputSchema: schema([:]),
        annotations: .init(readOnlyHint: true)
    ),
    Tool(
        name: "delegate",
        description: guide.toolDescription,
        inputSchema: schema([
            "prompt": prop("string", "Full task and output format; the model sees nothing else."),
            "files": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Absolute paths of text files the server reads and appends (instead of retyping them)."),
            ]),
            "model": prop("string", guide.modelParameterDescription),
            "task": prop("string", guide.tags.isEmpty ? "Task tag." : "Task tag: \(guide.tags.joined(separator: ", "))."),
            "sensitivity": .object([
                "type": .string("string"),
                "enum": .array(Sensitivity.allCases.map { .string($0.rawValue) }),
            ]),
            "system": prop("string", "System instruction."),
            "temperature": prop("number", "Temperature."),
            "max_tokens": prop("integer", "Reply token limit."),
            "json": prop("boolean", "Ask for a JSON reply."),
            "fallback": prop("boolean", "Default true; false = only the given model."),
            "allow_secrets": prop("boolean", "Default false; true only if detected keys/tokens are intentional."),
            "output_file": prop("string", "Absolute path; the server writes the reply there and returns only a short preview."),
            "background": prop("boolean", "Return a job ID at once; collect with delegate_result. Required for anything that may take over ~40 s (whole files, long output): sync calls are cut off at \(Int(DelegateRequest.syncDeadlineSeconds)) s."),
        ], required: ["prompt"])
    ),
    Tool(
        name: "delegate_result",
        description: "Status and results of background delegate jobs. Waits up to `wait` seconds for them to finish.",
        inputSchema: schema([
            "ids": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Job IDs; empty = all jobs of this session."),
            ]),
            "wait": prop("number", "Seconds to wait for unfinished jobs (default 0, max \(Int(DelegateJobs.maxWaitSeconds)))."),
        ]),
        annotations: .init(readOnlyHint: true)
    ),
    Tool(
        name: "list_remote_models",
        description: "Current model IDs from provider APIs, with suggested tags and prices (for update_models).",
        inputSchema: schema(["provider": prop("string", "Provider ID; empty = all.")]),
        annotations: .init(readOnlyHint: true)
    ),
    Tool(
        name: "update_models",
        description: "Upsert model tags and cost in delegate.toml. Cost: category (free, cheap, paid, varies) or price_in/price_out in USD per 1M tokens.",
        inputSchema: schema([
            "provider": prop("string", "Provider ID."),
            "models": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string")]),
                        "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                        "cost": .object(["type": .string("string")]),
                        "price_in": .object(["type": .string("number")]),
                        "price_out": .object(["type": .string("number")]),
                        "note": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("id")]),
                ]),
            ]),
        ], required: ["provider", "models"])
    ),
    Tool(
        name: "usage_summary",
        description: "Delegated calls, tokens, and cost from the local log.",
        inputSchema: schema(["days": prop("integer", "Recent days (default 7).")]),
        annotations: .init(readOnlyHint: true)
    ),
] }

let server = Server(
    name: "delegate",
    version: version,
    instructions: currentGuide().serverInstructions,
    capabilities: .init(tools: .init(listChanged: true))
)

await server.withMethodHandler(ListTools.self) { _ in .init(tools: makeTools(currentGuide(), clientName: await clientState.name)) }

await server.withMethodHandler(CallTool.self) { params in
    let a = params.arguments ?? [:]
    do {
        switch params.name {
        case "list_models":
            let config = (try? service.currentConfig()) ?? Config()
            let agents = AgentCatalog.describe(installed: agentInstaller.installed(), config: config,
                                               checks: AgentCheckCache(url: home.agentChecksURL).load(),
                                               clientName: await clientState.name)
            return .init(content: [reply(try service.listModels() + agents)], isError: false)

        case "delegate":
            guard let prompt = a["prompt"]?.stringValue, !prompt.isEmpty else {
                return .init(content: [reply("Missing parameter: prompt.")], isError: true)
            }
            let request = DelegateRequest(
                prompt: prompt,
                system: a["system"]?.stringValue,
                model: a["model"]?.stringValue,
                task: a["task"]?.stringValue,
                temperature: a["temperature"]?.doubleValue,
                maxTokens: a["max_tokens"]?.intValue,
                allowFallback: a["fallback"]?.boolValue ?? true,
                allowSecrets: a["allow_secrets"]?.boolValue ?? false,
                jsonMode: a["json"]?.boolValue ?? false,
                // Nieznana wartość: ostrożniej traktujemy ją jak dane osobiste, nie publiczne.
                sensitivity: Sensitivity(rawValue: a["sensitivity"]?.stringValue ?? "public") ?? .personal,
                files: a["files"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                outputFile: a["output_file"]?.stringValue
            )
            if a["background"]?.boolValue == true {
                try service.preflight(request)
                let id = await jobs.start(request)
                return .init(content: [reply("Started background job \(id). Keep working; collect with delegate_result.")], isError: false)
            }
            var sync = request
            sync.deadlineSeconds = DelegateRequest.syncDeadlineSeconds
            return .init(content: [reply(try await service.delegate(sync))], isError: false)

        case "delegate_result":
            let ids = a["ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let wait = a["wait"]?.doubleValue ?? a["wait"]?.intValue.map(Double.init) ?? 0
            return .init(content: [reply(await jobs.result(ids: ids, wait: wait))], isError: false)

        case "list_remote_models":
            return .init(content: [reply(try await service.listRemoteModels(providerID: a["provider"]?.stringValue))], isError: false)

        case "update_models":
            guard let provider = a["provider"]?.stringValue, let items = a["models"]?.arrayValue else {
                return .init(content: [reply("Required: provider and models.")], isError: true)
            }
            func number(_ v: Value?) -> Double? { v?.doubleValue ?? v?.intValue.map(Double.init) }
            let updates = items.compactMap { item -> ModelUpdate? in
                guard let o = item.objectValue, let id = o["id"]?.stringValue else { return nil }
                return ModelUpdate(
                    id: id,
                    tags: o["tags"]?.arrayValue?.compactMap(\.stringValue),
                    cost: o["cost"]?.stringValue,
                    priceIn: number(o["price_in"]),
                    priceOut: number(o["price_out"]),
                    note: o["note"]?.stringValue)
            }
            return .init(content: [reply(try service.updateModels(provider: provider, updates: updates))], isError: false)

        case "delegate_agent":
            guard let agentID = a["agent"]?.stringValue, let repo = a["repo"]?.stringValue,
                  let task = a["task"]?.stringValue, !task.isEmpty else {
                return .init(content: [reply("Required: agent, repo, task.")], isError: true)
            }
            let agentConfig = (try? service.currentConfig()) ?? Config()
            guard let agent = agentInstaller.installed(agentID) else {
                let ids = usableAgents(agentConfig).map(\.id)
                return .init(content: [reply("Agent \"\(agentID)\" isn't installed. Available: \(ids.isEmpty ? "none" : ids.joined(separator: ", ")).")], isError: true)
            }
            let repoURL = URL(fileURLWithPath: (repo as NSString).expandingTildeInPath)
            guard repo.hasPrefix("/") || repo.hasPrefix("~"), FileManager.default.fileExists(atPath: repoURL.path) else {
                return .init(content: [reply("repo: give an absolute path to an existing directory.")], isError: true)
            }
            let sensitivity = Sensitivity(rawValue: a["sensitivity"]?.stringValue ?? "public") ?? .personal
            let repoRoot = RepoSnapshot.toplevel(of: repoURL) ?? repoURL
            if let why = AgentRegions.refusal(agentID: agentID, sensitivity: sensitivity, config: agentConfig, repo: repoRoot) {
                return .init(content: [reply("Not sent: \(why).")], isError: true)
            }
            let reportFile = try a["report_file"]?.stringValue.map(OutputFile.validate)
            let settings = agentConfig.agentSettings(agentID)
            let model = a["model"]?.stringValue ?? settings?.model
            let effort = a["effort"]?.stringValue ?? settings?.effort
            let write = a["mode"]?.stringValue == "write"
            let branchFrom = a["branch_from"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            if branchFrom != nil && !write {
                return .init(content: [reply("branch_from works only with mode \"write\".")], isError: true)
            }
            let details = DelegateJobs.Details(agent: agentID, model: model, repo: repoRoot.path, write: write)
            let id = await jobs.start(label: "\(agentID)\(write ? " (write)" : ""): " + DelegateJobs.shortLabel(task),
                                      details: details, outcome: {
                await agentSlots.acquire()
                let started = Date()
                defer { Task { await agentSlots.release() } }
                do {
                    let report = try await agentRunner.run(agent: agent, repo: repoURL, task: task, model: model,
                                                           effort: effort, write: write, branchFrom: branchFrom)
                    usageLog.append(UsageEntry(provider: "agent:\(agentID)", model: report.model ?? "default", task: "agent",
                                               inputTokens: report.inputTokens, outputTokens: report.outputTokens,
                                               ok: true, ms: Int(report.seconds * 1000)))
                    let branch = report.branch.flatMap { $0.commits > 0 ? $0.branch : nil }
                    guard let reportFile else { return .init(text: report.formatted, branch: branch) }
                    // Podgląd zaczyna się od nagłówka raportu, więc go nie powtarzamy.
                    return .init(text: try OutputFile.write(report.formatted, to: reportFile), branch: branch)
                } catch {
                    usageLog.append(UsageEntry(provider: "agent:\(agentID)", model: model ?? "default", task: "agent",
                                               ok: false, error: "\(error)", ms: Int(Date().timeIntervalSince(started) * 1000)))
                    throw error
                }
            })
            let waiting = await agentSlots.queued
            let queueNote = waiting > 0 ? " \(waiting) job(s) are queued ahead (max \(agentSlots.limit) agents at once)." : ""
            return .init(content: [reply("Started agent job \(id) (\(agent.name), \(write ? "write" : "read") mode). It usually takes a few minutes; keep working and collect with delegate_result.\(queueNote)")], isError: false)

        case "usage_summary":
            return .init(content: [reply(service.usageSummary(days: a["days"]?.intValue ?? 7))], isError: false)

        default:
            return .init(content: [reply("Unknown tool: \(params.name)")], isError: true)
        }
    } catch {
        return .init(content: [reply("\(error)")], isError: true)
    }
}

try await server.start(transport: StdioTransport(), initializeHook: { info, _ in await clientState.set(info.name) })

// Zmiana zestawu agentów (instalacja, usunięcie, wyłączenie w apce): klient dostaje `tools/list_changed`
// i pobiera narzędzia od nowa, z aktualnym opisem `delegate_agent`.
Task {
    var last = usableAgents((try? service.currentConfig()) ?? Config()).map(\.id)
    while true {
        try? await Task.sleep(for: .seconds(30))
        let now = usableAgents((try? service.currentConfig()) ?? Config()).map(\.id)
        if now != last {
            last = now
            try? await server.notify(ToolListChangedNotification.message())
        }
    }
}
await server.waitUntilCompleted()
