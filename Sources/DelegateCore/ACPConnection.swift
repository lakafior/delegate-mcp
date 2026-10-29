import Foundation

/// Połączenie z agentem ACP (Agent Client Protocol): podproces, JSON-RPC 2.0 po stdio, jedna wiadomość na linię.
/// My jesteśmy klientem: wysyłamy `initialize`, `session/*`; agent wysyła nam powiadomienia (`session/update`)
/// i żądania (`session/request_permission`, `fs/*`), na które odpowiada `onRequest`.
/// Uruchomienie agenta w piaskownicy to sprawa wołającego (`executable` może być `sandbox-exec`).
public actor ACPConnection {
    /// Błąd zwrócony przez agenta w odpowiedzi JSON-RPC.
    public struct RemoteError: Error, Sendable, CustomStringConvertible {
        public var code: Int
        public var message: String
        public var data: JSONValue?

        public init(code: Int, message: String, data: JSONValue? = nil) {
            self.code = code
            self.message = message
            self.data = data
        }

        /// ACP: agent wymaga zalogowania (`authenticate`) przed sesją.
        public var isAuthRequired: Bool { code == ACPConnection.authRequiredCode }
        public var description: String { "agent error \(code): \(message)" }

        public static func methodNotFound(_ method: String) -> RemoteError {
            RemoteError(code: -32601, message: "Method not supported by this client: \(method)")
        }
    }

    public enum ConnectionError: Error, Sendable, CustomStringConvertible {
        case exited(status: Int32)
        case timeout(method: String)
        /// Agent przestał przysyłać cokolwiek (`abort` z watchdoga).
        case idle(seconds: Int)
        case badMessage(String)

        public var description: String {
            switch self {
            case .exited(let s): "agent exited (status \(s))"
            case .timeout(let m): "agent didn't answer \(m) in time"
            case .idle(let s): "agent sent nothing for \(s) s"
            case .badMessage(let m): "bad message from agent: \(m)"
            }
        }

        /// Koniec przez limit czasu albo ciszę: agent mógł już coś zrobić (częściowy raport, gałąź).
        public var isTimeLimit: Bool {
            switch self {
            case .timeout, .idle: true
            default: false
            }
        }
    }

    public typealias RequestHandler = @Sendable (_ method: String, _ params: JSONValue) async -> Result<JSONValue, RemoteError>
    public typealias NotificationHandler = @Sendable (_ method: String, _ params: JSONValue) async -> Void

    public static let protocolVersion = 1
    public static let authRequiredCode = -32000

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let onRequest: RequestHandler
    private let onNotification: NotificationHandler
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var nextID = 0
    private var closedError: ConnectionError?

    /// Uruchamia agenta. `stderr` agenta idzie do pliku albo w nicość, nigdy na nasz stdout
    /// (w serwerze MCP stdout należy do protokołu).
    public static func launch(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        stderrLog: URL? = nil,
        onRequest: @escaping RequestHandler = { method, _ in .failure(.methodNotFound(method)) },
        onNotification: @escaping NotificationHandler = { _, _ in }
    ) throws -> ACPConnection {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        if let stderrLog {
            FileManager.default.createFile(atPath: stderrLog.path, contents: nil)
            process.standardError = try FileHandle(forWritingTo: stderrLog)
        } else {
            process.standardError = FileHandle.nullDevice
        }
        try process.run()
        let connection = ACPConnection(process: process, input: stdin.fileHandleForWriting,
                                       output: stdout.fileHandleForReading,
                                       onRequest: onRequest, onNotification: onNotification)
        Task { await connection.readLoop() }
        return connection
    }

    private init(process: Process, input: FileHandle, output: FileHandle,
                 onRequest: @escaping RequestHandler, onNotification: @escaping NotificationHandler) {
        self.process = process
        self.input = input
        self.output = output
        self.onRequest = onRequest
        self.onNotification = onNotification
    }

    // MARK: wysyłanie

    /// Żądanie do agenta; czeka na odpowiedź (najwyżej `timeout`, jeśli podany).
    public func request(_ method: String, _ params: JSONValue = [:], timeout: Duration? = nil) async throws -> JSONValue {
        if let closedError { throw closedError }
        nextID += 1
        let id = nextID
        if let timeout {
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.fail(id, ConnectionError.timeout(method: method))
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try write(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
            } catch {
                fail(id, error)
            }
        }
    }

    /// Powiadomienie (bez odpowiedzi), np. `session/cancel`.
    public func notify(_ method: String, _ params: JSONValue = [:]) throws {
        if let closedError { throw closedError }
        try write(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    /// Kończy agenta; oczekujące żądania dostają błąd.
    public func close() {
        if process.isRunning { process.terminate() }
        finishAll(.exited(status: process.isRunning ? -1 : process.terminationStatus))
    }

    public var isRunning: Bool { process.isRunning }

    /// Przerywa oczekujące żądania tym błędem (np. agent przestał się odzywać); potem trzeba wywołać `close`.
    public func abort(_ error: ConnectionError) { finishAll(error) }

    private func write(_ message: JSONValue) throws {
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func fail(_ id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func finishAll(_ error: ConnectionError) {
        if closedError == nil { closedError = error }
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    // MARK: odbieranie

    private func readLoop() async {
        do {
            for try await line in output.bytes.lines {
                guard !line.isEmpty else { continue }
                guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
                await handle(message)
            }
        } catch {}
        process.waitUntilExit()
        finishAll(.exited(status: process.terminationStatus))
    }

    private func handle(_ message: JSONValue) async {
        if let method = message["method"]?.stringValue {
            let params = message["params"] ?? [:]
            if let id = message["id"] {
                // Żądanie od agenta: odpowiadamy osobnym zadaniem, żeby długa decyzja (np. pytanie użytkownika)
                // nie wstrzymywała odczytu kolejnych wiadomości.
                let onRequest = self.onRequest
                Task {
                    let result = await onRequest(method, params)
                    self.respond(id: id, result: result)
                }
            } else {
                // Powiadomienia po kolei: kolejność fragmentów odpowiedzi ma znaczenie.
                await onNotification(method, params)
            }
            return
        }
        guard let id = message["id"]?.intValue, let continuation = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] {
            continuation.resume(throwing: RemoteError(code: error["code"]?.intValue ?? 0,
                                                      message: error["message"]?.stringValue ?? "unknown error",
                                                      data: error["data"]))
        } else {
            continuation.resume(returning: message["result"] ?? .null)
        }
    }

    private func respond(id: JSONValue, result: Result<JSONValue, RemoteError>) {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": id]
        switch result {
        case .success(let value): message["result"] = value
        case .failure(let e):
            var error: [String: JSONValue] = ["code": .number(Double(e.code)), "message": .string(e.message)]
            if let data = e.data { error["data"] = data }
            message["error"] = .object(error)
        }
        try? write(.object(message))
    }
}

// MARK: pierwsze kroki protokołu

/// Co agent mówi o sobie w `initialize`.
public struct ACPAgentHello: Sendable, Equatable {
    public struct AuthMethod: Sendable, Equatable {
        public var id: String
        public var name: String
        /// `agent` (agent sam robi OAuth) albo `terminal` (interaktywne logowanie z `args`).
        public var type: String
        public var args: [String]
        public var env: [String: String]
        /// Osobny program do logowania (starszy zapis `_meta.terminal-auth`, np. Copilot: `copilot login`);
        /// `nil` = sam agent z `args`.
        public var command: String?

        public init(id: String, name: String, type: String, args: [String] = [], env: [String: String] = [:],
                    command: String? = nil) {
            self.id = id
            self.name = name
            self.type = type
            self.args = args
            self.env = env
            self.command = command
        }
    }

    public var name: String?
    public var version: String?
    public var protocolVersion: Int?
    public var authMethods: [AuthMethod]

    init(_ result: JSONValue) {
        let info = result["agentInfo"]
        name = info?["title"]?.stringValue ?? info?["name"]?.stringValue
        version = info?["version"]?.stringValue
        protocolVersion = result["protocolVersion"]?.intValue
        authMethods = (result["authMethods"]?.arrayValue ?? []).compactMap { m in
            guard let id = m["id"]?.stringValue else { return nil }
            // Starszy zapis (Zed, Copilot): bez `type`, logowanie w terminalu opisane w `_meta.terminal-auth`.
            if m["type"] == nil, let t = m["_meta"]?["terminal-auth"] {
                return AuthMethod(id: id, name: m["name"]?.stringValue ?? id, type: "terminal",
                                  args: t["args"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                  env: (t["env"]?.objectValue ?? [:]).compactMapValues(\.stringValue),
                                  command: t["command"]?.stringValue)
            }
            return AuthMethod(id: id, name: m["name"]?.stringValue ?? id,
                              type: m["type"]?.stringValue ?? "agent",
                              args: m["args"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                              env: (m["env"]?.objectValue ?? [:]).compactMapValues(\.stringValue))
        }
    }
}

extension ACPConnection {
    /// `initialize` z możliwościami klienta. Domyślnie bez `fs` i `terminal`: agent korzysta z własnych narzędzi,
    /// a granice wyznacza piaskownica.
    public func initialize(clientName: String = "delegate", clientVersion: String = "1",
                           readFiles: Bool = false, writeFiles: Bool = false, terminal: Bool = false,
                           timeout: Duration = .seconds(30)) async throws -> ACPAgentHello {
        let result = try await request("initialize", [
            "protocolVersion": .number(Double(Self.protocolVersion)),
            "clientCapabilities": ["fs": ["readTextFile": .bool(readFiles), "writeTextFile": .bool(writeFiles)],
                                   "terminal": .bool(terminal)],
            "clientInfo": ["name": .string(clientName), "version": .string(clientVersion)],
        ], timeout: timeout)
        return ACPAgentHello(result)
    }

    /// `authenticate` metodą typu `agent`: agent sam otwiera przeglądarkę i czeka na zalogowanie,
    /// więc limit jest długi.
    public func authenticate(methodId: String, timeout: Duration = .seconds(300)) async throws {
        _ = try await request("authenticate", ["methodId": .string(methodId)], timeout: timeout)
    }

    /// `session/new` w katalogu `cwd`. Brak logowania = `RemoteError.isAuthRequired`.
    public func newSession(cwd: URL, timeout: Duration = .seconds(60)) async throws -> ACPSession {
        let result = try await request("session/new", ["cwd": .string(cwd.path), "mcpServers": []], timeout: timeout)
        guard let session = ACPSession(result) else {
            throw ConnectionError.badMessage("session/new without sessionId")
        }
        return session
    }

    /// Ustawia opcję sesji (np. `mode` albo `model`), jeśli agent ją ogłosił z taką wartością.
    /// Agenci bez opcji konfiguracji, ale z trybami, dostają starsze `session/set_mode`.
    /// Zwraca `false`, gdy agent takiej opcji lub wartości nie zna.
    @discardableResult
    public func setOption(_ session: ACPSession, _ configId: String, _ value: String) async throws -> Bool {
        let isMode = configId == "mode"
        if let option = session.configOptions.first(where: { $0.id == configId || $0.category == configId }),
           let match = Self.match(value, in: option.values, mode: isMode) {
            _ = try await request("session/set_config_option", [
                "sessionId": .string(session.id), "configId": .string(option.id), "value": .string(match),
            ], timeout: .seconds(30))
            return true
        }
        if isMode, let match = Self.match(value, in: session.modes, mode: true) {
            _ = try await request("session/set_mode", ["sessionId": .string(session.id), "modeId": .string(match)],
                                  timeout: .seconds(30))
            return true
        }
        return false
    }

    /// Wartość ogłoszona przez agenta. Tryby bywają pełnymi adresami (Copilot 1.0.105:
    /// `https://agentclientprotocol.com/protocol/session-modes#plan`), więc `plan` pasuje też do końcówki `#plan`.
    static func match(_ value: String, in values: [String], mode: Bool) -> String? {
        if values.contains(value) { return value }
        return mode ? values.first { $0.hasSuffix("#" + value) } : nil
    }
}

/// Sesja agenta: ID oraz tryby i opcje, które agent ogłosił w `session/new`.
public struct ACPSession: Sendable, Equatable {
    public struct ConfigOption: Sendable, Equatable {
        public var id: String
        public var category: String?
        public var current: String?
        public var values: [String]
    }

    public var id: String
    public var modes: [String]
    public var configOptions: [ConfigOption]

    init?(_ result: JSONValue) {
        guard let id = result["sessionId"]?.stringValue else { return nil }
        self.id = id
        modes = (result["modes"]?["availableModes"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        configOptions = (result["configOptions"]?.arrayValue ?? []).compactMap { o in
            guard let id = o["id"]?.stringValue else { return nil }
            return ConfigOption(id: id, category: o["category"]?.stringValue,
                                current: o["currentValue"]?.stringValue,
                                values: (o["options"]?.arrayValue ?? []).compactMap { $0["value"]?.stringValue })
        }
    }

    /// Wartości opcji modelu (puste, gdy agent nie pozwala wybrać).
    public var models: [String] { modelOption?.values ?? [] }
    public var modelOption: ConfigOption? { configOptions.first { $0.category == "model" || $0.id == "model" } }

    /// Opcja wysiłku/myślenia: różnie nazywana (Claude Agent: `effort`/`thought_level`, Vibe: `thinking`).
    public var effortOption: ConfigOption? {
        configOptions.first { $0.category == "thought_level" || ["effort", "thinking", "thought_level", "reasoning"].contains($0.id) }
    }
}
