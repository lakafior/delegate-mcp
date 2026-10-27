import Foundation

/// Systemowy Node.js dla agentów ACP dystrybuowanych przez npm. Nie instalujemy własnego: szukamy tego,
/// który już jest. Aplikacje z GUI nie dostają `PATH` z terminala, więc oprócz `PATH` sprawdzamy typowe miejsca
/// (Homebrew, Volta, fnm, nvm). Ścieżki zostają nierozwinięte (`/opt/homebrew/bin/node` to link, który
/// przeżywa aktualizacje Node).
public struct NodeRuntime: Sendable, Equatable {
    public var node: URL
    public var npm: URL
    public var version: String

    public var binDirectory: URL { node.deletingLastPathComponent() }

    /// `PATH` dla agenta i npm: katalog Node na początku (skrypty z `#!/usr/bin/env node` i potomne `node`).
    public var path: String { "\(binDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin" }

    public static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> NodeRuntime? {
        for dir in candidateDirectories(home: home, environment: environment) {
            let node = dir.appendingPathComponent("node"), npm = dir.appendingPathComponent("npm")
            guard FileManager.default.isExecutableFile(atPath: node.path),
                  FileManager.default.isExecutableFile(atPath: npm.path),
                  let version = Self.version(of: node) else { continue }
            return NodeRuntime(node: node, npm: npm, version: version)
        }
        return nil
    }

    static func candidateDirectories(home: URL, environment: [String: String]) -> [URL] {
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0) }
        dirs += [".volta/bin", ".local/share/fnm/aliases/default/bin", ".asdf/shims"].map { home.appendingPathComponent($0) }
        // nvm: najnowsza zainstalowana wersja.
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? []
        if let latest = versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }).first {
            dirs.append(nvm.appendingPathComponent(latest).appendingPathComponent("bin"))
        }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0.path).inserted }
    }

    static func version(of node: URL) -> String? {
        let p = Process()
        p.executableURL = node
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let v = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}

/// Uruchomienie procesu bez blokowania wątku współbieżności (instalacja npm trwa nawet minutę).
func runProcess(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                currentDirectory: URL? = nil) async throws -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = executable
    p.arguments = arguments
    if let environment { p.environment = environment }
    if let currentDirectory { p.currentDirectoryURL = currentDirectory }
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("delegate-proc-\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: log) }
    let handle = try FileHandle(forWritingTo: log)
    p.standardOutput = handle
    p.standardError = handle
    p.standardInput = FileHandle.nullDevice
    let status: Int32 = try await withCheckedThrowingContinuation { cont in
        p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
        do { try p.run() } catch { p.terminationHandler = nil; cont.resume(throwing: error) }
    }
    try? handle.close()
    return (status, (try? String(contentsOf: log, encoding: .utf8)) ?? "")
}
