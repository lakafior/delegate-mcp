import DelegateCore
import Foundation
import MCP

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

let service = DelegateService(home: home)
let jobs = DelegateJobs(service: service)

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
func currentGuide() -> DelegationGuide {
    service.guide(config: (try? service.currentConfig()) ?? Config())
}

/// Lista narzędzi budowana na żądanie: opis `delegate` zawiera aktualne modele i tagi.
func makeTools(_ guide: DelegationGuide) -> [Tool] { [
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
            "background": prop("boolean", "Return a job ID at once; collect with delegate_result. Start several in one turn to run them in parallel."),
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
    capabilities: .init(tools: .init(listChanged: false))
)

await server.withMethodHandler(ListTools.self) { _ in .init(tools: makeTools(currentGuide())) }

await server.withMethodHandler(CallTool.self) { params in
    let a = params.arguments ?? [:]
    do {
        switch params.name {
        case "list_models":
            return .init(content: [reply(try service.listModels())], isError: false)

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
            return .init(content: [reply(try await service.delegate(request))], isError: false)

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

        case "usage_summary":
            return .init(content: [reply(service.usageSummary(days: a["days"]?.intValue ?? 7))], isError: false)

        default:
            return .init(content: [reply("Unknown tool: \(params.name)")], isError: true)
        }
    } catch {
        return .init(content: [reply("\(error)")], isError: true)
    }
}

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
