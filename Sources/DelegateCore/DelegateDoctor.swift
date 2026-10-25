import Foundation

public enum DiagnosticSeverity: String, Sendable, Codable {
    case ok
    case warning
    case error
}

public struct DiagnosticCheck: Sendable, Codable, Identifiable {
    public var id: String { name }
    public var name: String
    public var severity: DiagnosticSeverity
    public var message: String
    public var detail: String?
    public var fixable: Bool

    public init(name: String, severity: DiagnosticSeverity, message: String, detail: String? = nil, fixable: Bool = false) {
        self.name = name
        self.severity = severity
        self.message = message
        self.detail = detail
        self.fixable = fixable
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
        lines.append("=== Diagnostyka delegate-mcp ===")
        lines.append("")
        lines.append("Elementy systemu:")
        for c in checks {
            let icon = c.severity == .ok ? "✅" : (c.severity == .warning ? "⚠️" : "❌")
            lines.append("  \(icon) \(c.name): \(c.message)")
        }
        lines.append("")
        lines.append("Dostawcy i modele:")
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
        lines.append("Podsumowanie: \(okCount) OK, \(warnCount) ostrzeżeń, \(errCount) błędów.")
        return lines.joined(separator: "\n")
    }
}

public struct DelegateDoctor: Sendable {
    public let home: DelegateHome
    public let service: DelegateService

    public init(home: DelegateHome = DelegateHome.resolve(), service: DelegateService? = nil) {
        self.home = home
        self.service = service ?? DelegateService(home: home)
    }

    public func diagnose() async -> DiagnosticReport {
        var checks: [DiagnosticCheck] = []
        var providers: [ProviderDiagnostic] = []

        // 1. Config Check
        let configResult: Config?
        do {
            let text = try String(contentsOf: home.configURL, encoding: .utf8)
            let parsed = try Config.parse(text)
            configResult = parsed
            let modelsCount = parsed.providers.reduce(0) { $0 + $1.models.count }
            checks.append(DiagnosticCheck(
                name: "Konfiguracja (delegate.toml)",
                severity: .ok,
                message: "Plik poprawny (\(parsed.providers.count) dostawców, \(modelsCount) modeli)",
                detail: home.configURL.path
            ))
        } catch {
            configResult = nil
            checks.append(DiagnosticCheck(
                name: "Konfiguracja (delegate.toml)",
                severity: .error,
                message: "Błąd odczytu lub składni: \(error.localizedDescription)",
                detail: home.configURL.path
            ))
        }

        // 2. Claude Desktop Integration Check
        let desktopData = try? Data(contentsOf: ClaudeIntegration.desktopConfigURL)
        if let cmd = ClaudeIntegration.registeredCommand(in: desktopData) {
            let exists = FileManager.default.isExecutableFile(atPath: cmd)
            checks.append(DiagnosticCheck(
                name: "Claude Desktop",
                severity: exists ? .ok : .warning,
                message: exists ? "Serwer zarejestrowany (\(cmd))" : "Zarejestrowana ścieżka nie istnieje: \(cmd)",
                detail: ClaudeIntegration.desktopConfigURL.path,
                fixable: !exists
            ))
        } else {
            checks.append(DiagnosticCheck(
                name: "Claude Desktop",
                severity: .warning,
                message: "Brak wpisu delegate w claude_desktop_config.json",
                detail: ClaudeIntegration.desktopConfigURL.path,
                fixable: true
            ))
        }

        // 3. Claude Code Integration Check (CLAUDE.md)
        let claudeMDText = try? String(contentsOf: ClaudeIntegration.globalInstructionsURL, encoding: .utf8)
        let hasInstructions = claudeMDText.map(ClaudeIntegration.hasInstructions) ?? false
        checks.append(DiagnosticCheck(
            name: "Claude Code (~/.claude/CLAUDE.md)",
            severity: hasInstructions ? .ok : .warning,
            message: hasInstructions ? "Instrukcje delegowania zainstalowane" : "Brak instrukcji delegowania w ~/.claude/CLAUDE.md",
            detail: ClaudeIntegration.globalInstructionsURL.path,
            fixable: !hasInstructions
        ))

        // 4. Claude Code Subagent grunt Check
        let gruntText = try? String(contentsOf: ClaudeIntegration.gruntAgentURL, encoding: .utf8)
        let hasGrunt = ClaudeIntegration.gruntInstalled(gruntText)
        checks.append(DiagnosticCheck(
            name: "Subagent grunt (~/.claude/agents/grunt.md)",
            severity: hasGrunt ? .ok : .warning,
            message: hasGrunt ? "Agent grunt zainstalowany" : "Brak pliku agenta ~/.claude/agents/grunt.md",
            detail: ClaudeIntegration.gruntAgentURL.path,
            fixable: !hasGrunt
        ))

        // 5. On-Device Foundation Model Check
        switch service.onDevice.availability {
        case .available:
            checks.append(DiagnosticCheck(
                name: "Model na urządzeniu (Apple Foundation)",
                severity: .ok,
                message: "Dostępny i gotowy"
            ))
        case .unavailable(let why):
            checks.append(DiagnosticCheck(
                name: "Model na urządzeniu (Apple Foundation)",
                severity: .warning,
                message: "Niedostępny: \(why)"
            ))
        }

        // 6. Providers Check
        if let config = configResult {
            for p in config.providers {
                let st = service.status(of: p)
                let key = service.secrets.secret(for: p.apiKeyEnv)
                let keySource: String? = p.needsKey ? (key != nil ? "znaleziony" : "brak") : "nie wymagany"

                if !p.enabled {
                    providers.append(ProviderDiagnostic(
                        providerID: p.id,
                        kind: p.kind.rawValue,
                        status: "wyłączony",
                        keySource: keySource,
                        responseTimeMs: nil,
                        modelsCount: p.models.count,
                        error: nil,
                        severity: .warning
                    ))
                    continue
                }

                if case .missingKey(let envName) = st {
                    providers.append(ProviderDiagnostic(
                        providerID: p.id,
                        kind: p.kind.rawValue,
                        status: "brak klucza (\(envName))",
                        keySource: "brak",
                        responseTimeMs: nil,
                        modelsCount: p.models.count,
                        error: "Brak klucza w Keychain lub .env",
                        severity: .error
                    ))
                    continue
                }

                let start = Date()
                let testRes = await service.test(p)
                let ms = Int(Date().timeIntervalSince(start) * 1000)

                switch testRes {
                case .success(let info):
                    providers.append(ProviderDiagnostic(
                        providerID: p.id,
                        kind: p.kind.rawValue,
                        status: "gotowy (\(info))",
                        keySource: keySource,
                        responseTimeMs: ms,
                        modelsCount: p.models.count,
                        error: nil,
                        severity: .ok
                    ))
                case .failure(let err):
                    providers.append(ProviderDiagnostic(
                        providerID: p.id,
                        kind: p.kind.rawValue,
                        status: "błąd połączenia",
                        keySource: keySource,
                        responseTimeMs: ms,
                        modelsCount: p.models.count,
                        error: err.description,
                        severity: .error
                    ))
                }
            }
        }

        return DiagnosticReport(timestamp: Date(), checks: checks, providers: providers)
    }
}
