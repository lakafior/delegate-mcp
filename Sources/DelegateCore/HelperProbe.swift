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
        /// Narzędzia z `_meta["anthropic/alwaysLoad"]`: Claude Code nie chowa ich za ToolSearch.
        public var alwaysLoaded: [String] = []
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
            throw ProbeError(description: "no executable file: \(executable.path)")
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

        var version: String?
        var instructions = false
        var pending = Data()
        let result = try await read(stdout.fileHandleForReading, timeout: timeout,
                                    timeoutMessage: "no response within \(Int(timeout)) s") { chunk in
            guard let chunk else { throw ProbeError(description: "server exited without a response to tools/list") }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[..<newline]
                pending = Data(pending[pending.index(after: newline)...])
                guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                let result = msg["result"] as? [String: Any]
                switch msg["id"] as? Int {
                case 1:
                    version = (result?["serverInfo"] as? [String: Any])?["version"] as? String
                    instructions = !((result?["instructions"] as? String) ?? "").isEmpty
                case 2:
                    let list = result?["tools"] as? [[String: Any]] ?? []
                    let alwaysLoaded = list.filter { (($0["_meta"] as? [String: Any])?["anthropic/alwaysLoad"] as? Bool) == true }
                    return Handshake(serverVersion: version, hasInstructions: instructions,
                                     tools: list.compactMap { $0["name"] as? String },
                                     alwaysLoaded: alwaysLoaded.compactMap { $0["name"] as? String },
                                     ms: Int(Date().timeIntervalSince(started) * 1000))
                default:
                    continue
                }
            }
            return nil
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

        var collected = Data()
        let data = try await read(stdout.fileHandleForReading, timeout: timeout,
                                  timeoutMessage: "--check-keys: no response within \(Int(timeout)) s") { chunk in
            guard let chunk else { return collected }
            collected.append(chunk)
            return nil
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw ProbeError(description: "--check-keys: unreadable response (older server version?)")
        }
        return raw.compactMapValues(KeychainSecretStore.Access.init(rawValue:))
    }
}

extension HelperProbe {
    /// Czyta `handle` przez `readabilityHandler` (kolejka GCD, nie pula wątków Swift Concurrency: blokujące
    /// czytanie w zadaniach zagładzało ją na wolnych runnerach CI). `consume` dostaje kolejne kawałki, `nil` przy EOF,
    /// i zwraca wynik, gdy ma komplet. Po czasie kończy od razu, nie czekając na EOF: stdout może trzymać
    /// otwarty proces potomny, którego `terminate()` nie zabija.
    fileprivate func read<T: Sendable>(_ handle: FileHandle, timeout: TimeInterval, timeoutMessage: String,
                                       consume: @escaping (Data?) throws -> T?) async throws -> T {
        let once = OnceContinuation<T>()
        let consumer = Consumer(consume)
        defer { handle.readabilityHandler = nil }
        return try await withCheckedThrowingContinuation { continuation in
            once.set(continuation)
            handle.readabilityHandler = { h in
                let chunk = h.availableData
                do {
                    if let value = try consumer.call(chunk.isEmpty ? nil : chunk) {
                        once.resume(.success(value))
                    } else if chunk.isEmpty {
                        once.resume(.failure(ProbeError(description: "server exited without a response")))
                    }
                } catch {
                    once.resume(.failure(error))
                }
                if chunk.isEmpty || once.isDone { h.readabilityHandler = nil }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(.failure(ProbeError(description: timeoutMessage)))
            }
        }
    }
}

/// `readabilityHandler` jest `@Sendable`, ale FileHandle woła go szeregowo, więc stan w `consume` jest bezpieczny.
private final class Consumer<T>: @unchecked Sendable {
    let call: (Data?) throws -> T?
    init(_ call: @escaping (Data?) throws -> T?) { self.call = call }
}

/// Kontynuacja wznawiana dokładnie raz: wygrywa pierwszy z czytnika i timera.
private final class OnceContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var done = false

    var isDone: Bool { lock.withLock { done } }

    func set(_ c: CheckedContinuation<T, any Error>) { lock.withLock { continuation = c } }

    func resume(_ result: Result<T, any Error>) {
        let c: CheckedContinuation<T, any Error>? = lock.withLock {
            guard !done else { return nil }
            done = true
            defer { continuation = nil }
            return continuation
        }
        c?.resume(with: result)
    }
}
