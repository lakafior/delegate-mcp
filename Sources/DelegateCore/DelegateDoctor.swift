import Foundation

public enum DiagnosticSeverity: String, Sendable, Codable {
    case ok
    case warning
    case error
}

/// Co aplikacja umie naprawić jednym przyciskiem.
public enum DiagnosticFix: String, Sendable, Codable {
    case installDesktop, installCode, updateInstructions, authorizeKeys
}

/// Do grupowania w GUI: podpięcie w Claude osobno od reszty systemu.
public enum DiagnosticGroup: String, Sendable, Codable {
    case system, integration
}

public struct DiagnosticCheck: Sendable, Codable, Identifiable {
    public var id: String { name }
    public var name: String
    public var group: DiagnosticGroup
    public var severity: DiagnosticSeverity
    public var message: String
    public var detail: String?
    public var fix: DiagnosticFix?

    public var fixable: Bool { fix != nil }

    public init(name: String, severity: DiagnosticSeverity, message: String, detail: String? = nil,
                fix: DiagnosticFix? = nil, group: DiagnosticGroup = .system) {
        self.name = name
        self.group = group
        self.severity = severity
        self.message = message
        self.detail = detail
        self.fix = fix
    }
}

public struct ProviderDiagnostic: Sendable, Codable, Identifiable {
    public var id: String { providerID }
    public var providerID: String
    public var kind: String
    public var status: String
    public var keySource: String?
    public var responseTimeMs: Int?
    public var modelsCount: Int?
    public var error: String?
    public var severity: DiagnosticSeverity

    public init(
        providerID: String,
        kind: String,
        status: String,
        keySource: String? = nil,
        responseTimeMs: Int? = nil,
        modelsCount: Int? = nil,
        error: String? = nil,
        severity: DiagnosticSeverity
    ) {
        self.providerID = providerID
        self.kind = kind
        self.status = status
        self.keySource = keySource
        self.responseTimeMs = responseTimeMs
        self.modelsCount = modelsCount
        self.error = error
        self.severity = severity
    }
}

public struct DiagnosticReport: Sendable, Codable {
    public var timestamp: Date
    public var checks: [DiagnosticCheck]
    public var providers: [ProviderDiagnostic]

    public init(timestamp: Date = Date(), checks: [DiagnosticCheck], providers: [ProviderDiagnostic]) {
        self.timestamp = timestamp
        self.checks = checks
        self.providers = providers
    }

    public var allOk: Bool {
        !checks.contains { $0.severity == .error } && !providers.contains { $0.severity == .error }
    }

    public func terminalOutput() -> String {
        var lines: [String] = []
        lines.append("=== delegate-mcp diagnostics ===")
        lines.append("")
        lines.append("System items:")
        for c in checks {
            let icon = c.severity == .ok ? "✅" : (c.severity == .warning ? "⚠️" : "❌")
            lines.append("  \(icon) \(c.name): \(c.message)")
        }
        lines.append("")
        lines.append("Providers and models:")
        for p in providers {
            let icon = p.severity == .ok ? "✅" : (p.severity == .warning ? "⚠️" : "❌")
            var pLine = "  \(icon) \(p.providerID) (\(p.kind)) — \(p.status)"
            if let ms = p.responseTimeMs {
                pLine += " [\(ms) ms]"
            }
            if let err = p.error {
                pLine += " (\(err))"
            }
            lines.append(pLine)
        }
        lines.append("")
        let okCount = checks.filter { $0.severity == .ok }.count + providers.filter { $0.severity == .ok }.count
        let warnCount = checks.filter { $0.severity == .warning }.count + providers.filter { $0.severity == .warning }.count
        let errCount = checks.filter { $0.severity == .error }.count + providers.filter { $0.severity == .error }.count
        lines.append("Summary: \(okCount) OK, \(warnCount) warnings, \(errCount) errors.")
        return lines.joined(separator: "\n")
    }
}

public struct DelegateDoctor: Sendable {
    public let home: DelegateHome
    public let service: DelegateService
    /// Plik `delegate-mcp`, który Claude uruchamia. `nil`: bez testu serwera i dostępu do kluczy.
    public let helper: URL?

    public init(home: DelegateHome = DelegateHome.resolve(), service: DelegateService? = nil, helper: URL? = nil) {
        self.home = home
        self.service = service ?? DelegateService(home: home)
        self.helper = helper
    }

    public func diagnose() async -> DiagnosticReport {
        var checks: [DiagnosticCheck] = []
        var providers: [ProviderDiagnostic] = []

        // Konfiguracja
        let config: Config?
        do {
            let parsed = try Config.parse(String(contentsOf: home.configURL, encoding: .utf8))
            config = parsed
            let modelsCount = parsed.providers.reduce(0) { $0 + $1.models.count }
            checks.append(DiagnosticCheck(
                name: "Configuration (delegate.toml)", severity: .ok,
                message: "File valid (\(parsed.providers.count) providers, \(modelsCount) models)",
                detail: home.configURL.path))
        } catch {
            config = nil
            checks.append(DiagnosticCheck(
                name: "Configuration (delegate.toml)", severity: .error,
                message: "Read or syntax error: \(error.localizedDescription)",
                detail: home.configURL.path))
        }

        let desktop = ClaudeIntegration.registeredCommand(in: try? Data(contentsOf: ClaudeIntegration.desktopConfigURL))
        let code = ClaudeIntegration.registeredCommand(in: try? Data(contentsOf: ClaudeIntegration.claudeCodeConfigURL))
        let anyRegistered = desktop != nil || code != nil

        // Serwer tak, jak uruchamia go Claude: plik z jego configu, a gdy go brak, oczekiwany helper.
        var keyAccess: [String: KeychainSecretStore.Access]?
        if let helper {
            let target = [code, desktop].compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
                .map { URL(fileURLWithPath: $0) } ?? helper
            let probe = HelperProbe(executable: target, environment: helperEnvironment)
            do {
                let h = try await probe.handshake()
                let ok = h.tools.contains("delegate") && h.hasInstructions
                checks.append(DiagnosticCheck(
                    name: "MCP server", severity: ok ? .ok : .warning,
                    message: ok
                        ? "Responds in \(h.ms) ms (version \(h.serverVersion ?? "?"), \(h.tools.count) tools, \(h.alwaysLoaded.count) always loaded, instructions for Claude)"
                        : "Responds, but without instructions for Claude: this is an older version. Rebuild and reinstall the app.",
                    detail: target.path))
            } catch {
                checks.append(DiagnosticCheck(
                    name: "MCP server", severity: .error, message: "Not responding: \(error)", detail: target.path))
            }
            keyAccess = try? await probe.keyAccess()
        }

        // Podpięcie w Claude: wystarczy jedno z dwóch
        checks.append(integrationCheck(name: "Claude Desktop", command: desktop, anyRegistered: anyRegistered,
                                       detail: ClaudeIntegration.desktopConfigURL.path, fix: .installDesktop))
        checks.append(integrationCheck(name: "Claude Code", command: code, anyRegistered: anyRegistered,
                                       detail: ClaudeIntegration.claudeCodeConfigURL.path, fix: .installCode))

        // Blok w CLAUDE.md jest opcjonalny: instrukcje podaje sam serwer
        let claudeMD = (try? String(contentsOf: ClaudeIntegration.globalInstructionsURL, encoding: .utf8)) ?? ""
        if !ClaudeIntegration.hasInstructions(claudeMD) {
            checks.append(DiagnosticCheck(
                name: "Reminder in ~/.claude/CLAUDE.md", severity: .ok,
                message: "Not added (optional: the server provides the instructions itself)",
                detail: ClaudeIntegration.globalInstructionsURL.path, fix: .updateInstructions, group: .integration))
        } else if !ClaudeIntegration.instructionsUpToDate(claudeMD) {
            checks.append(DiagnosticCheck(
                name: "Reminder in ~/.claude/CLAUDE.md", severity: .warning,
                message: "Older version of the block (e.g. with the grunt subagent)",
                detail: ClaudeIntegration.globalInstructionsURL.path, fix: .updateInstructions, group: .integration))
        } else {
            checks.append(DiagnosticCheck(
                name: "Reminder in ~/.claude/CLAUDE.md", severity: .ok, message: "Up to date",
                detail: ClaudeIntegration.globalInstructionsURL.path, group: .integration))
        }

        // Model na urządzeniu: ostrzeżenie tylko, gdy jest włączony w configu
        let usesOnDevice = config?.providers.contains { $0.kind == .foundation && $0.enabled } ?? false
        switch service.onDevice.availability {
        case .available:
            checks.append(DiagnosticCheck(name: "On-device model (Apple)", severity: .ok, message: "Available"))
        case .unavailable(let why):
            checks.append(DiagnosticCheck(
                name: "On-device model (Apple)", severity: usesOnDevice ? .warning : .ok,
                message: usesOnDevice ? "Unavailable: \(why)" : "Unavailable (\(why)), not used"))
        }

        // Dostawcy
        var needsApproval: [String] = []
        for p in config?.providers ?? [] {
            let base = ProviderDiagnostic(providerID: p.id, kind: p.kind.rawValue, status: "", modelsCount: p.models.count, severity: .ok)
            if !p.enabled {
                providers.append(with(base) { $0.status = "disabled" })
                continue
            }
            if case .missingKey(let envName) = service.status(of: p) {
                providers.append(with(base) {
                    $0.status = "missing key (\(envName))"
                    $0.keySource = "none"
                    $0.error = "No key in Keychain or .env"
                    $0.severity = .error
                })
                continue
            }
            let serverAccess = p.needsKey ? keyAccess?[p.apiKeyEnv] : nil
            if serverAccess == .needsApproval { needsApproval.append(p.id) }

            let start = Date()
            let result = await service.test(p)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            switch result {
            case .success(let info):
                providers.append(with(base) {
                    $0.status = serverAccess == .needsApproval ? "works, but the server will ask for the key password" : "ready (\(info))"
                    $0.keySource = p.needsKey ? "found" : "not required"
                    $0.responseTimeMs = ms
                    $0.severity = serverAccess == .needsApproval ? .warning : .ok
                })
            case .failure(let err):
                providers.append(with(base) {
                    $0.status = "connection error"
                    $0.responseTimeMs = ms
                    $0.error = err.description
                    $0.severity = .error
                })
            }
        }
        if helper != nil {
            if !needsApproval.isEmpty {
                checks.append(DiagnosticCheck(
                    name: "Server access to keys", severity: .warning,
                    message: "Server will ask for the Keychain password for: \(needsApproval.joined(separator: ", "))",
                    fix: .authorizeKeys))
            } else if keyAccess != nil {
                checks.append(DiagnosticCheck(name: "Server access to keys", severity: .ok, message: "No password prompt"))
            } else if config?.providers.contains(where: { $0.enabled && $0.needsKey }) == true {
                checks.append(DiagnosticCheck(
                    name: "Server access to keys", severity: .warning,
                    message: "Not checked: the connected server is older than the app. Rebuild and reinstall the app."))
            }
        }

        // Czy Claude w ogóle deleguje
        let week = Calendar.current.date(byAdding: .day, value: -7, to: Date())
        let recent = service.usage.entries(since: week)
        let ok = recent.filter(\.ok).count
        checks.append(DiagnosticCheck(
            name: "Delegation in the last 7 days",
            severity: recent.isEmpty && anyRegistered ? .warning : .ok,
            message: recent.isEmpty
                ? "No calls. Restart Claude after changes; the server instructions load at session start."
                : "\(recent.count) calls (successful: \(ok))"))

        return DiagnosticReport(timestamp: Date(), checks: checks, providers: providers)
    }

    /// Środowisko dla helpera: to samo, ale z naszym katalogiem domowym (ważne przy `DELEGATE_HOME`).
    private var helperEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["DELEGATE_HOME"] = home.directory.path
        return env
    }

    private func integrationCheck(name: String, command: String?, anyRegistered: Bool, detail: String, fix: DiagnosticFix) -> DiagnosticCheck {
        guard let command else {
            return DiagnosticCheck(
                name: name, severity: anyRegistered ? .ok : .error,
                message: anyRegistered ? "Not connected (optional)" : "Not connected: Claude doesn't see the server",
                detail: detail, fix: fix, group: .integration)
        }
        if !FileManager.default.isExecutableFile(atPath: command) {
            return DiagnosticCheck(name: name, severity: .error, message: "Points to a nonexistent file: \(command)", detail: detail, fix: fix, group: .integration)
        }
        if let helper, command != helper.path {
            return DiagnosticCheck(name: name, severity: .warning, message: "Points to a different binary: \(command)", detail: detail, fix: fix, group: .integration)
        }
        return DiagnosticCheck(name: name, severity: .ok, message: "Connected (\(command))", detail: detail, group: .integration)
    }

    private func with(_ value: ProviderDiagnostic, _ change: (inout ProviderDiagnostic) -> Void) -> ProviderDiagnostic {
        var copy = value
        change(&copy)
        return copy
    }
}
