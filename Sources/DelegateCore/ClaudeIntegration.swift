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
    ## Delegowanie i tańsze modele
    Przy prostych zadaniach nie używaj głównego modelu, jeśli tańszy wystarczy:
    1. Mechaniczna praca na repo lub plikach (szukanie w kodzie, przemianowania, testy wg istniejącego
       wzorca, streszczanie logów): oddaj subagentowi `grunt` (Haiku).
    2. Zadanie samowystarczalne w samym tekście (tłumaczenie, pierwszy draft, streszczenie wklejonego
       tekstu, druga opinia o fragmencie kodu, masowe generowanie): najpierw `list_models`, potem
       `delegate` zgodnie z routing_guidance. Modele z `delegate` widzą tylko prompt, więc wklej cały kontekst.
    3. Decyzje projektowe, debugowanie, zmiany obejmujące wiele plików, bezpieczeństwo: rób sam.
    Wynik zawsze zweryfikuj. Do `delegate` nie wysyłaj danych z pracy, sekretów ani danych osobowych
    (to zewnętrzni dostawcy); `grunt` działa w ramach Claude, więc takich ograniczeń nie ma.
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

    // MARK: subagent `grunt`

    public static var gruntAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/agents/grunt.md")
    }

    public static let gruntAgent = """
    ---
    name: grunt
    description: Mechaniczna praca na repo: szukanie w kodzie, przemianowania, testy wg istniejącego wzorca, streszczanie logów. Użyj, gdy nie trzeba decyzji projektowych.
    model: haiku
    ---
    \(marker)
    Wykonaj dokładnie to zadanie, które dostałeś. Jeśli okaże się, że wymaga decyzji projektowej
    albo wykracza poza zakres, zatrzymaj się i opisz, co znalazłeś, zamiast zgadywać.
    Na końcu podaj krótkie podsumowanie: co zrobiłeś, które pliki zmieniłeś, co zostało niepewne.
    """

    public static func gruntInstalled(_ text: String?) -> Bool { text?.contains(marker) == true }

    public static func removingInstructions(from text: String) -> String {
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3 else { return text }
        let rest = parts[0] + parts[2...].joined(separator: marker)
        return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : rest.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
