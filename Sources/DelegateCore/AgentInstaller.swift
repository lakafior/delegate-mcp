import CryptoKit
import Foundation

/// Zainstalowany agent ACP: co uruchomić, żeby z nim rozmawiać.
public struct InstalledAgent: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    /// Ścieżka absolutna do pliku wykonywalnego agenta.
    public var executable: String
    public var args: [String]
    public var env: [String: String]
    public var installedAt: Date
}

/// Instaluje agentów z rejestru ACP do własnego katalogu (`Delegate/agents/<id>/<wersja>/`), jak Zed:
/// nic nie trafia do `PATH` ani do systemu, usunięcie agenta to usunięcie katalogu.
/// Archiwum musi mieć sumę SHA-256 z rejestru; bez zgodnej sumy nic nie instalujemy.
public struct AgentInstaller: Sendable {
    let directory: URL
    let transport: any HTTPTransport

    public init(directory: URL, transport: any HTTPTransport = URLSessionTransport()) {
        self.directory = directory
        self.transport = transport
    }

    var manifestURL: URL { directory.appendingPathComponent("installed.json") }

    // MARK: lista

    public func installed() -> [InstalledAgent] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let all = (try? decoder.decode([InstalledAgent].self, from: data)) ?? []
        // Wpis bez pliku (ktoś skasował katalog ręcznie) nie jest zainstalowany.
        return all.filter { FileManager.default.isExecutableFile(atPath: $0.executable) }
    }

    public func installed(_ id: String) -> InstalledAgent? { installed().first { $0.id == id } }

    // MARK: instalacja

    @discardableResult
    public func install(_ agent: ACPRegistry.Agent) async throws -> InstalledAgent {
        guard case .binary(let target) = agent.installKind else {
            if case .needsRuntime(let tool) = agent.installKind {
                throw DelegateError(description: "\(agent.name) needs \(tool); only standalone binaries are supported for now.")
            }
            throw DelegateError(description: "\(agent.name) has no build for this Mac.")
        }
        guard let expected = target.sha256?.lowercased(), !expected.isEmpty else {
            throw DelegateError(description: "\(agent.name): the registry gives no SHA-256 checksum, refusing to install.")
        }
        guard let url = URL(string: target.archive), url.scheme == "https" else {
            throw DelegateError(description: "\(agent.name): archive URL must be https.")
        }

        var req = URLRequest(url: url, timeoutInterval: 600)
        req.httpMethod = "GET"
        let (data, http) = try await transport.send(req)
        guard (200..<300).contains(http.statusCode) else {
            throw DelegateError(description: "\(agent.name): download failed (HTTP \(http.statusCode)).")
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw DelegateError(description: "\(agent.name): checksum mismatch, the download may be corrupted or tampered with.")
        }

        let fm = FileManager.default
        let agentDir = directory.appendingPathComponent(Self.safeComponent(agent.id), isDirectory: true)
        let staging = agentDir.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let archive = staging.appendingPathComponent(url.lastPathComponent)
        try data.write(to: archive)
        let content = staging.appendingPathComponent("content", isDirectory: true)
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
        let relative = try Self.commandPath(target.cmd)
        let stagedExecutable = content.appendingPathComponent(relative)
        if Self.isArchive(archive) {
            try Self.extract(archive, into: content)
        } else {
            // Niektórzy agenci w rejestrze to gołe pliki wykonywalne, bez archiwum.
            try fm.createDirectory(at: stagedExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: archive, to: stagedExecutable)
        }
        guard fm.fileExists(atPath: stagedExecutable.path) else {
            throw DelegateError(description: "\(agent.name): archive has no \(target.cmd).")
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedExecutable.path)

        let final = agentDir.appendingPathComponent(Self.safeComponent(agent.version), isDirectory: true)
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: content, to: final)

        let entry = InstalledAgent(id: agent.id, name: agent.name, version: agent.version,
                                   executable: final.appendingPathComponent(relative).path,
                                   args: target.args ?? [], env: target.env ?? [:], installedAt: Date())
        var all = installedIncludingMissing().filter { $0.id != agent.id }
        all.append(entry)
        try save(all)
        // Starsze wersje sprzątamy dopiero po zapisaniu nowej.
        for old in (try? fm.contentsOfDirectory(at: agentDir, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent != final.lastPathComponent && !old.lastPathComponent.hasPrefix(".staging-") {
            try? fm.removeItem(at: old)
        }
        return entry
    }

    public func uninstall(_ id: String) throws {
        try save(installedIncludingMissing().filter { $0.id != id })
        let dir = directory.appendingPathComponent(Self.safeComponent(id), isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }

    /// Czy w rejestrze jest nowsza (inna) wersja niż zainstalowana.
    public func hasUpdate(_ agent: ACPRegistry.Agent) -> Bool {
        installed(agent.id).map { $0.version != agent.version } ?? false
    }

    // MARK: pomocnicze

    private func installedIncludingMissing() -> [InstalledAgent] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([InstalledAgent].self, from: data)) ?? []
    }

    private func save(_ all: [InstalledAgent]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all.sorted { $0.id < $1.id }).write(to: manifestURL, options: .atomic)
    }

    /// `cmd` z rejestru (np. `./vibe-acp`) jako ścieżka względna wewnątrz archiwum; nic poza nim.
    static func commandPath(_ cmd: String) throws -> String {
        let parts = cmd.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
        guard !cmd.hasPrefix("/"), !parts.isEmpty, !parts.contains("..") else {
            throw DelegateError(description: "Unsafe command path in registry: \(cmd)")
        }
        return parts.joined(separator: "/")
    }

    /// ID i wersje z rejestru idą do nazw katalogów: bez ukośników i kropek na początku.
    static func safeComponent(_ s: String) -> String {
        let cleaned = s.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "_" }
        let result = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return result.isEmpty ? "_" : result
    }

    static let tarSuffixes = [".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz", ".tar"]

    static func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".zip") || tarSuffixes.contains { name.hasSuffix($0) }
    }

    static func extract(_ archive: URL, into dir: URL) throws {
        let name = archive.lastPathComponent.lowercased()
        let tool: String, args: [String]
        if tarSuffixes.contains(where: { name.hasSuffix($0) }) {
            // bsdtar sam rozpoznaje kompresję i bez `-P` odrzuca ścieżki z `..` i absolutne.
            (tool, args) = ("/usr/bin/tar", ["-xf", archive.path, "-C", dir.path])
        } else if name.hasSuffix(".zip") {
            (tool, args) = ("/usr/bin/ditto", ["-x", "-k", archive.path, dir.path])
        } else {
            throw DelegateError(description: "Unsupported archive format: \(archive.lastPathComponent)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw DelegateError(description: "Couldn't unpack \(archive.lastPathComponent) (\(tool) exit \(p.terminationStatus)).")
        }
        // Linki symboliczne wychodzące poza katalog agenta byłyby furtką poza instalację.
        let root = dir.resolvingSymlinksInPath().path
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let url as URL in files {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
            let target = url.resolvingSymlinksInPath().path
            guard target == root || target.hasPrefix(root + "/") else {
                throw DelegateError(description: "Archive contains a link outside the agent folder: \(url.lastPathComponent)")
            }
        }
    }
}

extension DelegateHome {
    /// Katalog agentów ACP: instalacje, `installed.json` i kopia rejestru.
    public var agentsURL: URL { directory.appendingPathComponent("agents", isDirectory: true) }
    public var agentRegistryURL: URL { agentsURL.appendingPathComponent("registry.json") }
}
