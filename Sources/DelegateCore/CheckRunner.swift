import Foundation

/// Wynik polecenia `check` (kryterium akceptacji zadania).
public struct CheckResult: Sendable, Equatable {
    public var command: String
    public var passed: Bool
    public var exitCode: Int32
    /// Koniec wyjścia (stdout + stderr), tyle, ile trzeba do poprawki.
    public var output: String
    public var seconds: Double
    /// Ile rund poprawek było potrzebnych (0 = przeszło od razu).
    public var fixes = 0

    /// Jedna linia dla dyrygenta.
    public var line: String {
        let after = fixes == 0 ? "" : " after \(fixes) fix\(fixes == 1 ? "" : "es")"
        return passed ? "✓ check `\(command)` passed\(after)" : "✗ check `\(command)` failed\(after) (exit \(exitCode))"
    }
}

/// Uruchamia `check` dyrygenta jak senior sprawdzający pracę juniora: polecenie (testy, build, walidator) w katalogu
/// zadania, w piaskownicy. Zapis tylko do katalogu zadania, tmp i cache narzędzi; bez Keychain; sieć tylko na życzenie
/// (agent w trybie zapisu i tak jej używał, `delegate` jej nie potrzebuje).
public struct CheckRunner: Sendable {
    let delegateHome: DelegateHome
    let userHome: URL
    let useSandbox: Bool
    public static let defaultTimeout: TimeInterval = 300
    /// Tyle końcowych znaków wyjścia trafia do poprawki i do dyrygenta.
    static let tailCharacters = 3000

    public init(home: DelegateHome, userHome: URL = FileManager.default.homeDirectoryForCurrentUser, useSandbox: Bool = true) {
        self.delegateHome = home
        self.userHome = userHome
        self.useSandbox = useSandbox
    }

    public func run(_ command: String, in directory: URL, writable: [URL] = [], network: Bool = false,
                    timeout: TimeInterval = defaultTimeout) async -> CheckResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: runBlocking(command, in: directory, writable: writable, network: network, timeout: timeout))
            }
        }
    }

    func runBlocking(_ command: String, in directory: URL, writable: [URL], network: Bool, timeout: TimeInterval) -> CheckResult {
        let started = Date()
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("delegate-check-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        func failed(_ why: String) -> CheckResult {
            CheckResult(command: command, passed: false, exitCode: -1, output: why, seconds: Date().timeIntervalSince(started))
        }

        var executable = URL(fileURLWithPath: "/bin/sh")
        var arguments = ["-c", command]
        if useSandbox {
            guard AgentSandbox.isAvailable else { return failed("sandbox-exec is missing; checks don't run without a sandbox") }
            var sandbox = AgentSandbox(home: userHome,
                                       writable: [directory, tmp] + writable + AgentSandbox.buildDirectories(home: userHome),
                                       readOnly: [], hidden: AgentSandbox.defaultHidden(home: userHome, delegateHome: delegateHome))
            sandbox.network = network
            sandbox.keychain = false
            let profile = tmp.appendingPathComponent("check.sb")
            do { try sandbox.profile().write(to: profile, atomically: true, encoding: .utf8) } catch { return failed("\(error)") }
            (executable, arguments) = sandbox.command(profileURL: profile, executable: executable, arguments: arguments)
        }
        let log = tmp.appendingPathComponent("output.log")
        fm.createFile(atPath: log.path, contents: nil)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(AgentSandbox.temporaryEnvironment(tmp)) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        guard let handle = try? FileHandle(forWritingTo: log) else { return failed("can't capture output") }
        process.standardOutput = handle
        process.standardError = handle
        do { try process.run() } catch { return failed("can't start: \(error)") }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()
        try? handle.close()
        var output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let timedOut = Date().timeIntervalSince(started) >= timeout
        if timedOut { output += "\n(stopped after \(Int(timeout)) s)" }
        if output.count > Self.tailCharacters { output = "…" + output.suffix(Self.tailCharacters) }
        return CheckResult(command: command, passed: process.terminationStatus == 0 && !timedOut, exitCode: process.terminationStatus,
                           output: output.trimmingCharacters(in: .whitespacesAndNewlines), seconds: Date().timeIntervalSince(started))
    }
}
