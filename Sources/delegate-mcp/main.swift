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
            "allow_secrets": prop("boolean", "Domyślnie false. Ustaw true, jeśli celowo wysyłasz fragmenty kodu zawierające klucze lub tokeny API."),
            "json": prop("boolean", "Domyślnie false. Ustaw true, aby wymusić odpowiedź w poprawnym formacie JSON."),
        ], required: ["prompt"])
    ),
    Tool(
        name: "list_remote_models",
        description: "Pyta API dostawcy o aktualne ID modeli (do aktualizacji delegate.toml). Bez argumentu: wszyscy dostawcy z kluczem.",
        inputSchema: schema(["provider": prop("string", "ID dostawcy, np. mistral.")]),
        annotations: .init(readOnlyHint: true)
    ),
    Tool(
        name: "update_models",
        description: "Zapisuje tagi i koszt modeli w delegate.toml (upsert). Użyj po list_remote_models, żeby uzupełnić tagi i dodać nowe modele. Koszt: kategoria (free, cheap, paid, varies) ALBO ceny w USD za 1M tokenów (price_in, price_out). Nie dotyka kluczy API.",
        inputSchema: schema([
            "provider": prop("string", "ID dostawcy, np. mistral."),
            "models": .object([
                "type": .string("array"),
                "description": .string("Modele do zmiany lub dodania."),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": prop("string", "ID modelu u dostawcy."),
                        "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                         "description": .string("Pełna lista tagów, np. code, translate, reasoning.")]),
                        "cost": prop("string", "Kategoria: free, cheap, paid, varies."),
                        "price_in": prop("number", "USD za 1M tokenów wejścia."),
                        "price_out": prop("number", "USD za 1M tokenów wyjścia."),
                        "note": prop("string", "Krótka uwaga."),
                    ]),
                    "required": .array([.string("id")]),
                ]),
            ]),
        ], required: ["provider", "models"])
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
