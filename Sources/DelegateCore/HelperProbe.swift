import Foundation

/// Sprawdza serwer tak, jak widzi go Claude: uruchamia wskazany plik `delegate-mcp`, robi
/// handshake MCP i pyta (osobnym uruchomieniem), czy odczyta klucze bez okna z hasłem.
public struct HelperProbe: Sendable {
    public let executable: URL
    public let environment: [String: String]?

    public init(executable: URL, environment: [String: String]? = nil) {
        self.executable = executable
        self.environment = environment
    }

    public struct Handshake: Sendable, Equatable {
        public var serverVersion: String?
        public var hasInstructions: Bool
        public var tools: [String]
        public var ms: Int
    }

    public struct ProbeError: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    private func makeProcess(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        if let environment { p.environment = environment }
        return p
    }

    /// `initialize` → `notifications/initialized` → `tools/list`; stdin zostaje otwarte do odpowiedzi.
    public func handshake(timeout: TimeInterval = 10) async throws -> Handshake {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProbeError(description: "brak pliku wykonywalnego: \(executable.path)")
        }
        let process = makeProcess([])
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let started = Date()
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"delegate-doctor","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ]
        try stdin.fileHandleForWriting.write(contentsOf: Data((requests.joined(separator: "\n") + "\n").utf8))

        let reader = stdout.fileHandleForReading
        let kill = ProcessBox(process)
        let result = try await withThrowingTaskGroup(of: Handshake.self) { group in
            group.addTask {
                var version: String?
                var instructions = false
                for try await line in reader.bytes.lines {
                    guard let msg = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                    let result = msg["result"] as? [String: Any]
                    switch msg["id"] as? Int {
                    case 1:
                        version = (result?["serverInfo"] as? [String: Any])?["version"] as? String
                        instructions = !((result?["instructions"] as? String) ?? "").isEmpty
                    case 2:
                        let tools = (result?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                        return Handshake(serverVersion: version, hasInstructions: instructions, tools: tools,
                                         ms: Int(Date().timeIntervalSince(started) * 1000))
                    default:
                        continue
                    }
                }
                throw ProbeError(description: "serwer zakończył pracę bez odpowiedzi na tools/list")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                // Grupa czeka na wszystkie zadania: zabicie procesu zamyka stdout i kończy czytanie.
                kill.process.terminate()
                throw ProbeError(description: "brak odpowiedzi w \(Int(timeout)) s")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        try? stdin.fileHandleForWriting.close()
        return result
    }

    /// Wynik `delegate-mcp --check-keys`: nazwa klucza → dostęp.
    public func keyAccess(timeout: TimeInterval = 10) async throws -> [String: KeychainSecretStore.Access] {
        let process = makeProcess(["--check-keys"])
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let reader = stdout.fileHandleForReading
        let kill = ProcessBox(process)
        let data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try reader.readToEnd() ?? Data() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                kill.process.terminate()
                throw ProbeError(description: "--check-keys: brak odpowiedzi w \(Int(timeout)) s")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw ProbeError(description: "--check-keys: nieczytelna odpowiedź (starsza wersja serwera?)")
        }
        return raw.compactMapValues(KeychainSecretStore.Access.init(rawValue:))
    }
}

/// `Process` nie jest `Sendable`; tylko do `terminate()` z zadania pilnującego czasu.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}
