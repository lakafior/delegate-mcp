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

let tools: [Tool] = [
    Tool(
        name: "list_models",
        description: "Lista dostawców i modeli wg priorytetu, z tagami, kosztami, statusem klucza i zasadami routingu. Wywołaj przed delegate.",
        inputSchema: schema([:]),
        annotations: .init(readOnlyHint: true)
    ),
    Tool(
        name: "delegate",
        description: "Oddaje samodzielne zadanie innemu modelowi (model widzi tylko prompt, bez plików i narzędzi). Wskaż model (provider/model), tag (task) albo zostaw puste: wtedy wg priorytetu. Przy błędzie próbuje następnych. Nie wysyłaj sekretów ani danych osobowych.",
        inputSchema: schema([
            "prompt": prop("string", "Pełna treść zadania, z całym potrzebnym kontekstem."),
            "model": prop("string", "Konkretny model, np. mistral/mistral-small-latest."),
            "task": prop("string", "Tag zadania, np. code, translate, summarize, reasoning."),
            "system": prop("string", "Opcjonalna instrukcja systemowa."),
            "temperature": prop("number", "Opcjonalna temperatura."),
            "max_tokens": prop("integer", "Opcjonalny limit tokenów odpowiedzi."),
            "fallback": prop("boolean", "Domyślnie true. false = tylko wskazany model."),
        ], required: ["prompt"])
    ),
    Tool(
        name: "list_remote_models",
        description: "Pyta API dostawcy o aktualne ID modeli (do aktualizacji delegate.toml). Bez argumentu: wszyscy dostawcy z kluczem.",
        inputSchema: schema(["provider": prop("string", "ID dostawcy, np. mistral.")]),
        annotations: .init(readOnlyHint: true)
    ),
    Tool(
        name: "usage_summary",
        description: "Podsumowanie wywołań i tokenów z lokalnego logu.",
        inputSchema: schema(["days": prop("integer", "Z ilu ostatnich dni (domyślnie 7).")]),
        annotations: .init(readOnlyHint: true)
    ),
]

let server = Server(
    name: "delegate",
    version: version,
    capabilities: .init(tools: .init(listChanged: false))
)

await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }

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
                allowFallback: a["fallback"]?.boolValue ?? true
            )
            return .init(content: [reply(try await service.delegate(request))], isError: false)

        case "list_remote_models":
            return .init(content: [reply(try await service.listRemoteModels(providerID: a["provider"]?.stringValue))], isError: false)

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
