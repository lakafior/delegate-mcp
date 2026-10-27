import Foundation

/// Kopia repo dla agenta: `git worktree` na commicie, który zawiera też niezacommitowane zmiany śledzonych
/// plików (`git stash create` nie rusza working tree). Pliki nieśledzone i ignorowane (np. `.env`) do kopii
/// nie trafiają. Oryginalne repo zostaje nietknięte.
public struct RepoSnapshot: Sendable {
    /// Katalog główny oryginalnego repo.
    public let repo: URL
    public let path: URL
    public let commit: String
    public let includesUncommitted: Bool
    /// Wspólny katalog `.git` oryginalnego repo (obiekty i metadane worktree).
    public let gitDirectory: URL

    public static func create(repo: URL, at path: URL) throws -> RepoSnapshot {
        let top: String
        do {
            top = try git(["rev-parse", "--show-toplevel"], in: repo)
        } catch {
            throw DelegateError(description: "\(repo.path) is not a git repository.")
        }
        let root = URL(fileURLWithPath: top)
        let stash = (try? git(["stash", "create"], in: root)) ?? ""
        let commit: String
        if !stash.isEmpty {
            commit = stash
        } else {
            do {
                commit = try git(["rev-parse", "HEAD"], in: root)
            } catch {
                throw DelegateError(description: "\(root.lastPathComponent) has no commits yet.")
            }
        }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try git(["worktree", "add", "--detach", path.path, commit], in: root)
        let common = (try? git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root))
            .map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent(".git")
        return RepoSnapshot(repo: root, path: path, commit: commit, includesUncommitted: !stash.isEmpty, gitDirectory: common)
    }

    /// Usuwa kopię i jej wpis w `.git/worktrees`.
    public func remove() {
        _ = try? Self.git(["worktree", "remove", "--force", path.path], in: repo)
        _ = try? Self.git(["worktree", "prune"], in: repo)
        try? FileManager.default.removeItem(at: path)
    }

    @discardableResult
    static func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DelegateError(description: "git \(args.first ?? ""): \(msg)")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Piaskownica macOS (`sandbox-exec`) dla agenta. Protokół ACP nie gwarantuje, że agent zapyta o zgodę
/// (Vibe w trybie `ask` uruchamiał polecenia bez pytania), więc granice wyznacza system:
/// zapis tylko do katalogów stanu agenta i katalogu tymczasowego zadania, kopia repo tylko do odczytu,
/// wrażliwe pliki niewidoczne. Procesy potomne agenta dziedziczą profil. Sieć jest dozwolona (model jest w chmurze).
public struct AgentSandbox: Sendable {
    public var home: URL
    /// Zapis dozwolony (stan agenta: tokeny, cache; katalog tymczasowy zadania).
    public var writable: [URL]
    /// Tylko do odczytu, nawet jeśli leżą w `writable` (kopia repo).
    public var readOnly: [URL]
    /// Niewidoczne dla agenta (klucze, tokeny, oryginalne repo z plikami spoza gita).
    public var hidden: [URL]
    /// Wyjątki od `hidden` tylko do odczytu, np. `.git` oryginalnego repo: worktree trzyma tam swoje metadane,
    /// więc bez tego `git log` w kopii nie działa. Pliki spoza gita (np. `.env`) zostają ukryte.
    public var readableExceptions: [URL] = []
    /// Katalogi, których same metadane (`stat`) są widoczne, choć zawartość nie (git sprawdza ścieżkę oryginalnego repo).
    public var metadataExceptions: [URL] = []

    public static let executable = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                writable: [URL], readOnly: [URL], hidden: [URL]) {
        self.home = home
        self.writable = writable
        self.readOnly = readOnly
        self.hidden = hidden
    }

    /// Profil SBPL. Późniejsza reguła wygrywa, więc kolejność: zakaz zapisu, wyjątki, kopia repo, ukryte.
    public func profile() -> String {
        func rules(_ urls: [URL]) -> String {
            urls.map { u in
                let path = Self.realPath(u)
                return "(subpath \"\(Self.escape(path))\")"
            }.joined(separator: " ")
        }
        var lines = [
            "(version 1)",
            "(allow default)",
            "(deny file-write* \(rules([home, URL(fileURLWithPath: "/Volumes"), URL(fileURLWithPath: "/private/tmp"), URL(fileURLWithPath: "/private/var/folders")])))",
        ]
        if !writable.isEmpty { lines.append("(allow file-write* \(rules(writable)))") }
        if !readOnly.isEmpty { lines.append("(deny file-write* \(rules(readOnly)))") }
        if !hidden.isEmpty { lines.append("(deny file-read* file-write* \(rules(hidden)))") }
        if !readableExceptions.isEmpty { lines.append("(allow file-read* \(rules(readableExceptions)))") }
        if !metadataExceptions.isEmpty {
            let literals = metadataExceptions.map { "(literal \"\(Self.escape(Self.realPath($0)))\")" }.joined(separator: " ")
            lines.append("(allow file-read-metadata \(literals))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Polecenie uruchomienia agenta w piaskownicy.
    public func command(profileURL: URL, executable: URL, arguments: [String]) -> (URL, [String]) {
        (Self.executable, ["-f", profileURL.path, executable.path] + arguments)
    }

    /// Katalogi stanu znanych agentów (tam trzymają logowanie i cache). Nieznani: `~/.<id>`.
    /// Agenci z npm dostają jeszcze cache npm (niektórzy doinstalowują zależności przy starcie).
    public static func stateDirectories(forAgent id: String, kind: String? = nil, home: URL) -> [URL] {
        let known: [String: [String]] = [
            "mistral-vibe": [".vibe"],
            "gemini": [".gemini"],
            "antigravity-acp": [".gemini/antigravity-acp", ".gemini/antigravity"],
            "opencode": [".local/share/opencode", ".config/opencode", ".cache/opencode"],
            "goose": [".config/goose", ".local/share/goose"],
            "kimi": [".kimi"],
            "github-copilot-cli": [".copilot", ".config/github-copilot"],
            "claude-acp": [".claude", ".claude.json"],
            "codex-acp": [".codex"],
            "qwen-code": [".qwen"],
            "kilo": [".kilocode", ".config/kilo", ".local/share/kilo"],
        ]
        let dirs = (known[id] ?? [".\(id)"]) + (kind == "npm" ? [".npm"] : [])
        return dirs.map { home.appendingPathComponent($0) }
    }

    /// Zmienne kierujące pliki tymczasowe agenta do katalogu zadania (jedyne zapisywalne `tmp` w piaskownicy).
    /// Claude Code (Claude Agent) trzyma pliki powłoki w osobnym katalogu, nie w `TMPDIR`; bez tego jego Bash nie startuje.
    public static func temporaryEnvironment(_ dir: URL) -> [String: String] {
        let path = dir.path.hasSuffix("/") ? dir.path : dir.path + "/"
        return ["TMPDIR": path, "CLAUDE_CODE_TMPDIR": path]
    }

    /// Co zawsze ukrywamy przed agentem.
    public static func defaultHidden(home: URL, delegateHome: DelegateHome) -> [URL] {
        [".ssh", ".aws", ".gnupg", ".netrc", ".docker", ".kube", ".config/gh", ".git-credentials", ".npmrc", ".pypirc"]
            .map { home.appendingPathComponent($0) } + [delegateHome.envURL]
    }

    /// `sandbox-exec` porównuje ścieżki po rozwinięciu linków (`/tmp` → `/private/tmp`).
    static func realPath(_ url: URL) -> String {
        let resolved = url.resolvingSymlinksInPath().path
        if resolved.hasPrefix("/tmp/") || resolved == "/tmp" { return "/private" + resolved }
        if resolved.hasPrefix("/var/") { return "/private" + resolved }
        return resolved
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
