import Foundation

/// Stan logowania agenta: sprawdzany próbną sesją (`session/new` bez logowania kończy się `auth_required`).
public enum AgentSignIn: Sendable, Equatable {
    case signedIn
    case needsSignIn([ACPAgentHello.AuthMethod])
    case failed(String)
}

/// Logowanie i sprawdzanie agentów (dla apki). Tokeny trzyma sam agent w swoim katalogu; my ich nie widzimy.
public enum AgentAccount {
    public struct Check: Sendable, Equatable {
        public var signIn: AgentSignIn
        /// Modele, które agent ogłasza w sesji (pusta lista, gdy nie pozwala wybrać albo sesja się nie udała).
        public var models: [String]
        public var defaultModel: String?
        public var authMethods: [ACPAgentHello.AuthMethod]
    }

    /// Uruchamia agenta w pustym katalogu tymczasowym: `initialize` + `session/new`. Nic nie wysyła modelowi.
    public static func check(_ agent: InstalledAgent) async -> Check {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("delegate-agent-check-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let conn: ACPConnection
        do {
            conn = try ACPConnection.launch(executable: URL(fileURLWithPath: agent.executable), arguments: agent.args,
                                            environment: agent.env, workingDirectory: dir)
        } catch {
            return Check(signIn: .failed("Can't start \(agent.name): \(error)"), models: [], defaultModel: nil, authMethods: [])
        }
        var methods: [ACPAgentHello.AuthMethod] = []
        do {
            let hello = try await conn.initialize()
            methods = hello.authMethods
            let session = try await conn.newSession(cwd: dir)
            await conn.close()
            let modelOption = session.configOptions.first { $0.category == "model" || $0.id == "model" }
            return Check(signIn: .signedIn, models: session.models, defaultModel: modelOption?.current, authMethods: methods)
        } catch let e as ACPConnection.RemoteError where e.isAuthRequired {
            await conn.close()
            return Check(signIn: .needsSignIn(methods), models: [], defaultModel: nil, authMethods: methods)
        } catch {
            await conn.close()
            return Check(signIn: .failed("\(error)"), models: [], defaultModel: nil, authMethods: methods)
        }
    }

    /// Logowanie metodą typu `agent`: agent otwiera przeglądarkę, my czekamy na wynik (do 5 min).
    public static func signIn(_ agent: InstalledAgent, method: ACPAgentHello.AuthMethod) async throws {
        let conn = try ACPConnection.launch(executable: URL(fileURLWithPath: agent.executable), arguments: agent.args,
                                            environment: agent.env)
        do {
            _ = try await conn.initialize()
            try await conn.authenticate(methodId: method.id)
            await conn.close()
        } catch {
            await conn.close()
            throw error
        }
    }

    /// Polecenie dla logowania typu `terminal`: argumenty metody zastępują zwykłe argumenty agenta.
    public static func terminalCommand(_ agent: InstalledAgent, method: ACPAgentHello.AuthMethod) -> String {
        let env = agent.env.merging(method.env) { _, new in new }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(shellQuote($0.value))" }
        return (env + [shellQuote(agent.executable)] + method.args.map(shellQuote)).joined(separator: " ")
    }

    /// Otwiera Terminal z poleceniem logowania (plik `.command` w katalogu tymczasowym, bez uprawnień do automatyzacji).
    public static func openTerminalSignIn(_ agent: InstalledAgent, method: ACPAgentHello.AuthMethod) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("delegate-sign-in-\(agent.id).command")
        try "#!/bin/zsh\n\(terminalCommand(agent, method: method))\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "Terminal", file.path]
        try open.run()
        open.waitUntilExit()
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
