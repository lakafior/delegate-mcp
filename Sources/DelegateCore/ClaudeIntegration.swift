import Foundation

/// Podpięcie serwera w Claude Desktop / Claude Code oraz blok instrukcji dla `~/.claude/CLAUDE.md`.
public enum ClaudeIntegration {
    public static let serverName = "delegate"
    public static let marker = "<!-- delegate-mcp -->"

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
                throw DelegateError(description: "claude_desktop_config.json is not a JSON object")
            }
            root = obj
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if let command { servers[serverName] = ["command": command] } else { servers.removeValue(forKey: serverName) }
        if servers.isEmpty && command == nil { root.removeValue(forKey: "mcpServers") } else { root["mcpServers"] = servers }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Krótki blok do `~/.claude/CLAUDE.md`. Szczegóły (kiedy delegować, dostępne modele) serwer
    /// podaje sam w instrukcjach MCP, więc blok tylko wzmacnia nawyk i nie dubluje configu.
    public static let instructions = """
    \(marker)
    ## Delegating to cheaper models
    You have the `delegate` MCP tool to save my Claude usage limits. It pays off for long, file-shaped output \
    (whole locale files, many fixtures, long docs) and for big inputs you would otherwise read (logs, long \
    files: ask for a short report); for short outputs the extra turns cost more than writing it yourself. \
    Keep it to one round trip: `files` in, `output_file` out, one `git diff` review, small fixes with an Edit. \
    Follow the `delegate` server instructions for which model and `sensitivity`. Never send secrets, personal \
    data, or work material to regions that don't allow it.
    \(marker)
    """

    public static func hasInstructions(_ text: String) -> Bool { text.contains(marker) }

    /// Czy blok w pliku jest identyczny z aktualnym wzorcem.
    public static func instructionsUpToDate(_ text: String) -> Bool { text.contains(instructions) }

    /// Dopisuje blok albo podmienia istniejący (np. starszą wersję) w miejscu.
    public static func addingInstructions(to text: String) -> String {
        let parts = text.components(separatedBy: marker)
        if parts.count >= 3 {
            return parts[0] + instructions + parts[2...].joined(separator: marker)
        }
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
