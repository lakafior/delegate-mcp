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
    /// `binary` albo `npm` (wtedy `executable` to systemowy `node`, a skrypt agenta jest w `args`).
    public var kind: String?
    /// Katalog instalacji; jego brak = agent usunięty ręcznie.
    public var installDir: String?

    public init(id: String, name: String, version: String, executable: String, args: [String],
                env: [String: String], installedAt: Date, kind: String? = nil, installDir: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.executable = executable
        self.args = args
        self.env = env
        self.installedAt = installedAt
        self.kind = kind
        self.installDir = installDir
    }
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
        // Wpis bez pliku (ktoś skasował katalog ręcznie albo odinstalował Node) nie jest zainstalowany.
        return all.filter {
            FileManager.default.isExecutableFile(atPath: $0.executable)
                && ($0.installDir.map { FileManager.default.fileExists(atPath: $0) } ?? true)
        }
    }

    public func installed(_ id: String) -> InstalledAgent? { installed().first { $0.id == id } }

    // MARK: instalacja

    /// `node`: systemowy Node.js dla agentów z npm (`NodeRuntime.find()`); bez niego takie agenty odpadają.
    @discardableResult
    public func install(_ agent: ACPRegistry.Agent, node: NodeRuntime? = NodeRuntime.find()) async throws -> InstalledAgent {
        switch agent.installKind {
        case .binary(let target):
            return try await installBinary(agent, target)
        case .npm(let target):
            guard let node else {
                throw DelegateError(description: "\(agent.name) needs Node.js; install it (e.g. brew install node) and try again.")
            }
            return try await installNpm(agent, target, node: node)
        case .needsRuntime(let tool):
            throw DelegateError(description: "\(agent.name) needs \(tool), which isn't supported yet.")
        case .unavailable:
            throw DelegateError(description: "\(agent.name) has no build for this Mac.")
        }
    }

    private func installBinary(_ agent: ACPRegistry.Agent, _ target: ACPRegistry.BinaryTarget) async throws -> InstalledAgent {
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

        let final = try promote(content, agent: agent, agentDir: agentDir)
        return try record(InstalledAgent(id: agent.id, name: agent.name, version: agent.version,
                                         executable: final.appendingPathComponent(relative).path,
                                         args: target.args ?? [], env: target.env ?? [:], installedAt: Date(),
                                         kind: "binary", installDir: final.path), agentDir: agentDir, keep: final)
    }

    /// Paczka npm instalowana raz (`npm install --prefix`) do katalogu agenta; uruchamiana przez systemowy
    /// `node` bez `npx`, więc bez sieci i bez niespodziewanych aktualizacji przy starcie. Skrypty instalacyjne
    /// paczek (`postinstall`) są wyłączone: to cudzy kod, który inaczej wykonałby się poza piaskownicą.
    /// Integralność paczek sprawdza npm (sumy `integrity` z rejestru npm); rejestr ACP sumy nie podaje.
    private func installNpm(_ agent: ACPRegistry.Agent, _ target: ACPRegistry.PackageTarget, node: NodeRuntime) async throws -> InstalledAgent {
        let fm = FileManager.default
        let agentDir = directory.appendingPathComponent(Self.safeComponent(agent.id), isDirectory: true)
        let staging = agentDir.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let content = staging.appendingPathComponent("content", isDirectory: true)
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = node.path
        let (status, output) = try await runProcess(node.npm, [
            "install", "--prefix", content.path, "--no-audit", "--no-fund", "--omit=dev", "--ignore-scripts",
            target.package,
        ], environment: env)
        guard status == 0 else {
            let tail = output.split(separator: "\n").suffix(6).joined(separator: "\n")
            throw DelegateError(description: "\(agent.name): npm install failed (exit \(status)).\n\(tail)")
        }
        let script = try Self.npmBinScript(in: content, agentID: agent.id)
        let final = try promote(content, agent: agent, agentDir: agentDir)
        let finalScript = final.appendingPathComponent(String(script.path.dropFirst(content.path.count + 1)))
        var agentEnv = target.env ?? [:]
        agentEnv["PATH"] = node.path
        return try record(InstalledAgent(id: agent.id, name: agent.name, version: agent.version,
                                         executable: node.node.path, args: [finalScript.path] + (target.args ?? []),
                                         env: agentEnv, installedAt: Date(), kind: "npm", installDir: final.path),
                          agentDir: agentDir, keep: final)
    }

    /// Skrypt startowy zainstalowanej paczki: nazwa z `package.json` katalogu instalacji, plik z pola `bin`
    /// (jedyny wpis, albo ten nazwany jak paczka lub agent).
    static func npmBinScript(in prefix: URL, agentID: String) throws -> URL {
        func json(_ url: URL) -> [String: Any]? {
            (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        guard let deps = json(prefix.appendingPathComponent("package.json"))?["dependencies"] as? [String: Any],
              let name = deps.keys.sorted().first else {
            throw DelegateError(description: "npm installed nothing into \(prefix.lastPathComponent).")
        }
        let packageDir = prefix.appendingPathComponent("node_modules").appendingPathComponent(name)
        let manifest = json(packageDir.appendingPathComponent("package.json")) ?? [:]
        let bin: String?
        if let single = manifest["bin"] as? String {
            bin = single
        } else if let map = manifest["bin"] as? [String: String] {
            let short = String(name.split(separator: "/").last ?? "")
            bin = map.count == 1 ? map.values.first : (map[short] ?? map[agentID] ?? map.keys.sorted().first.flatMap { map[$0] })
        } else {
            bin = nil
        }
        guard let bin else { throw DelegateError(description: "\(name) declares no executable (package.json \"bin\").") }
        let script = packageDir.appendingPathComponent(bin).standardizedFileURL
        guard script.path.hasPrefix(packageDir.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: script.path) else {
            throw DelegateError(description: "\(name): executable \(bin) is missing or outside the package.")
        }
        return script
    }

    /// Przenosi przygotowaną zawartość na miejsce wersji.
    private func promote(_ content: URL, agent: ACPRegistry.Agent, agentDir: URL) throws -> URL {
        let fm = FileManager.default
        let final = agentDir.appendingPathComponent(Self.safeComponent(agent.version), isDirectory: true)
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: content, to: final)
        return final
    }

    /// Zapisuje wpis w `installed.json` i dopiero potem sprząta starsze wersje.
    private func record(_ entry: InstalledAgent, agentDir: URL, keep final: URL) throws -> InstalledAgent {
        var all = installedIncludingMissing().filter { $0.id != entry.id }
        all.append(entry)
        try save(all)
        for old in (try? FileManager.default.contentsOfDirectory(at: agentDir, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent != final.lastPathComponent && !old.lastPathComponent.hasPrefix(".staging-") {
            try? FileManager.default.removeItem(at: old)
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
