import Foundation

/// Klienci MCP obsługiwani przez instalator serwera `delegate`.
public enum MCPClient: String, CaseIterable, Sendable {
    /// Dokumentacja: https://docs.cursor.com/context/model-context-protocol
    case cursor
    /// Dokumentacja: https://code.visualstudio.com/docs/agents/reference/mcp-configuration
    case vscode
    /// Dokumentacja: https://google-gemini.github.io/gemini-cli/docs/tools/mcp-server.html
    case geminiCLI
    /// Dokumentacja: https://antigravity.google/docs/mcp
    case antigravity
    /// Dokumentacja: https://zed.dev/docs/ai/mcp
    case zed

    public var title: String {
        switch self {
        case .cursor: "Cursor"
        case .vscode: "Visual Studio Code"
        case .geminiCLI: "Gemini CLI"
        case .antigravity: "Antigravity"
        case .zed: "Zed"
        }
    }

    /// Położenie konfiguracji użytkownika zgodne z dokumentacją danego klienta.
    public var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .cursor:
            return home.appendingPathComponent(".cursor/mcp.json")
        case .vscode:
            return home.appendingPathComponent("Library/Application Support/Code/User/mcp.json")
        case .geminiCLI:
            return home.appendingPathComponent(".gemini/settings.json")
        case .antigravity:
            return home.appendingPathComponent(".gemini/config/mcp_config.json")
        case .zed:
            return home.appendingPathComponent(".config/zed/settings.json")
        }
    }
}

/// Odczyt i aktualizacja wpisu serwera MCP w konfiguracjach innych klientów.
public enum MCPClientConfig {
    private enum Schema {
        case mcpServers
        case vscodeServers
        case contextServers

        var key: String {
            switch self {
            case .mcpServers: "mcpServers"
            case .vscodeServers: "servers"
            case .contextServers: "context_servers"
            }
        }
    }

    private static func schema(for client: MCPClient) -> Schema {
        switch client {
        case .cursor, .geminiCLI, .antigravity: .mcpServers
        case .vscode: .vscodeServers
        case .zed: .contextServers
        }
    }

    /// Zwraca ścieżkę polecenia z wpisu `delegate`.
    public static func registeredCommand(in data: Data?, for client: MCPClient) -> String? {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root[schema(for: client).key] as? [String: Any],
              let entry = servers["delegate"] as? [String: Any] else { return nil }
        return entry["command"] as? String
    }

    /// Dodaje albo usuwa wpis serwera; pozostałe klucze konfiguracji pozostają zachowane.
    public static func updating(_ data: Data?, for client: MCPClient, command: String?) throws -> Data {
        var root: [String: Any] = [:]
        if let data, !data.isEmpty {
            let parsed: Any
            do {
                parsed = try JSONSerialization.jsonObject(with: data)
            } catch {
                if client == .zed {
                    throw DelegateError(description: "Zed settings.json contains JSONC; add the delegate entry by hand")
                }
                throw error
            }
            guard let object = parsed as? [String: Any] else {
                if client == .zed {
                    throw DelegateError(description: "Zed settings.json must be edited by hand")
                }
                throw DelegateError(description: "MCP client configuration is not a JSON object")
            }
            root = object
        }

        let schema = schema(for: client)
        var servers = root[schema.key] as? [String: Any] ?? [:]
        if let command {
            var entry: [String: Any] = ["command": command]
            if client == .vscode { entry["type"] = "stdio" }
            servers["delegate"] = entry
        } else {
            servers.removeValue(forKey: "delegate")
        }

        if servers.isEmpty && command == nil {
            root.removeValue(forKey: schema.key)
        } else {
            root[schema.key] = servers
        }
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
