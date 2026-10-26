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
        print(created ? "Utworzono \(home.configURL.path)" : "Już istnieje: \(home.configURL.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Błąd: \(error)\n".utf8))
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
        description: "Full catalog of providers and models by priority, with tags, costs, key status, and routing rules. Optional: `delegate` already knows the available models and tags.",
        inputSchema: schema([:]),
        annotations: .init(readOnlyHint: true)
    ),
    Tool(
        name: "delegate",
        description: guide.toolDescription,
        inputSchema: schema([
            "prompt": prop("string", "The complete task with all needed context; the model sees nothing else."),
            "model": prop("string", guide.modelParameterDescription),
            "task": prop("string", guide.tags.isEmpty
                ? "Task tag, e.g. translate, summarize, code."
                : "Task tag that picks the model. Available: \(guide.tags.joined(separator: ", "))."),
            "system": prop("string", "Optional system instruction for the delegated model."),
            "temperature": prop("number", "Optional sampling temperature."),
            "max_tokens": prop("integer", "Optional limit on reply tokens."),
            "fallback": prop("boolean", "Default true. false = use only the given model, no fallback."),
            "allow_secrets": prop("boolean", "Default false. The server blocks prompts that look like they contain API keys or tokens; set true only if that content is intentional and safe to send."),
            "json": prop("boolean", "Default false. true = ask the model for a valid JSON reply."),
        ], required: ["prompt"])
    ),
    Tool(
        name: "list_remote_models",
        description: "Asks provider APIs for current model IDs with suggested tags, context size, and prices when the API exposes them (to update delegate.toml). No argument: all providers with a key.",
        inputSchema: schema(["provider": prop("string", "Provider ID, e.g. mistral.")]),
        annotations: .init(readOnlyHint: true)
    ),
    Tool(
        name: "update_models",
        description: "Saves model tags and cost in delegate.toml (upsert). Use after list_remote_models to fill tags/prices and add new models. Cost is a category (free, cheap, paid, varies) OR USD per 1M tokens (price_in, price_out). Never touches API keys.",
        inputSchema: schema([
            "provider": prop("string", "Provider ID, e.g. mistral."),
            "models": .object([
                "type": .string("array"),
                "description": .string("Models to change or add."),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": prop("string", "Model ID at the provider."),
                        "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                         "description": .string("Full tag list, e.g. code, translate, reasoning.")]),
                        "cost": prop("string", "Category: free, cheap, paid, varies."),
                        "price_in": prop("number", "USD per 1M input tokens."),
                        "price_out": prop("number", "USD per 1M output tokens."),
                        "note": prop("string", "Short note."),
                    ]),
                    "required": .array([.string("id")]),
                ]),
            ]),
        ], required: ["provider", "models"])
    ),
    Tool(
        name: "usage_summary",
        description: "Summary of delegated calls, tokens, and cost from the local log.",
        inputSchema: schema(["days": prop("integer", "How many recent days (default 7).")]),
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
                return .init(content: [reply("Brak parametru prompt.")], isError: true)
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
                jsonMode: a["json"]?.boolValue ?? false
            )
            return .init(content: [reply(try await service.delegate(request))], isError: false)

        case "list_remote_models":
            return .init(content: [reply(try await service.listRemoteModels(providerID: a["provider"]?.stringValue))], isError: false)

        case "update_models":
            guard let provider = a["provider"]?.stringValue, let items = a["models"]?.arrayValue else {
                return .init(content: [reply("Wymagane: provider i models.")], isError: true)
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
            return .init(content: [reply("Nieznane narzędzie: \(params.name)")], isError: true)
        }
    } catch {
        return .init(content: [reply("\(error)")], isError: true)
    }
}

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
