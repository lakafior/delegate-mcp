import Foundation

/// Podpięcie serwera w Claude Desktop / Claude Code oraz blok instrukcji dla `~/.claude/CLAUDE.md`.
public enum ClaudeIntegration {
    public static let serverName = "delegate"
    static let marker = "<!-- delegate-mcp -->"

    public static var desktopConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    /// Tu Claude Code trzyma serwery o zasięgu `user`.
    public static var claudeCodeConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    public static var globalInstructionsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/CLAUDE.md")
    }

    /// Ścieżka z wpisu `mcpServers.delegate.command`, jeśli jest.
    public static func registeredCommand(in data: Data?) -> String? {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let entry = servers[serverName] as? [String: Any] else { return nil }
        return entry["command"] as? String
    }

    /// Zwraca JSON z dopisanym (`command != nil`) albo usuniętym wpisem; reszta pliku zostaje.
    public static func updatingDesktopConfig(_ data: Data?, command: String?) throws -> Data {
        var root: [String: Any] = [:]
        if let data, !data.isEmpty {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DelegateError(description: "claude_desktop_config.json nie jest obiektem JSON")
            }
            root = obj
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if let command { servers[serverName] = ["command": command] } else { servers.removeValue(forKey: serverName) }
        if servers.isEmpty && command == nil { root.removeValue(forKey: "mcpServers") } else { root["mcpServers"] = servers }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public static let instructions = """
    \(marker)
    ## Delegowanie
    Masz serwer MCP `delegate`. Przy zadaniach samowystarczalnych (masowe generowanie,
    tłumaczenia, pierwsze drafty, streszczenia wklejonego tekstu, druga opinia o fragmencie kodu)
    najpierw wywołaj `list_models`, potem `delegate` zgodnie z routing_guidance.
    Wynik zawsze zweryfikuj. Nie wysyłaj danych z pracy, sekretów ani danych osobowych.
    \(marker)
    """

    public static func hasInstructions(_ text: String) -> Bool { text.contains(marker) }

    public static func addingInstructions(to text: String) -> String {
        guard !hasInstructions(text) else { return text }
        let sep = text.isEmpty ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n")
        return text + sep + instructions + "\n"
    }

    public static func removingInstructions(from text: String) -> String {
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3 else { return text }
        let rest = parts[0] + parts[2...].joined(separator: marker)
        return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : rest.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
