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

public struct DiagnosticCheck: Sendable, Codable, Identifiable {
    public var id: String { name }
    public var name: String
    public var severity: DiagnosticSeverity
    public var message: String
    public var detail: String?
    public var fix: DiagnosticFix?

    public var fixable: Bool { fix != nil }

    public init(name: String, severity: DiagnosticSeverity, message: String, detail: String? = nil, fix: DiagnosticFix? = nil) {
        self.name = name
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
                name: "Konfiguracja (delegate.toml)", severity: .ok,
                message: "Plik poprawny (\(parsed.providers.count) dostawców, \(modelsCount) modeli)",
                detail: home.configURL.path))
        } catch {
            config = nil
            checks.append(DiagnosticCheck(
                name: "Konfiguracja (delegate.toml)", severity: .error,
                message: "Błąd odczytu lub składni: \(error.localizedDescription)",
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
                    name: "Serwer MCP", severity: ok ? .ok : .warning,
                    message: ok
                        ? "Odpowiada w \(h.ms) ms (wersja \(h.serverVersion ?? "?"), \(h.tools.count) narzędzi, instrukcje dla Claude'a)"
                        : "Odpowiada, ale bez instrukcji dla Claude'a: to starsza wersja. Przebuduj i zainstaluj aplikację.",
                    detail: target.path))
            } catch {
                checks.append(DiagnosticCheck(
                    name: "Serwer MCP", severity: .error, message: "Nie odpowiada: \(error)", detail: target.path))
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
                name: "Przypomnienie w ~/.claude/CLAUDE.md", severity: .ok,
                message: "Nie dodano (opcjonalne: serwer sam podaje instrukcje)",
                detail: ClaudeIntegration.globalInstructionsURL.path, fix: .updateInstructions))
        } else if !ClaudeIntegration.instructionsUpToDate(claudeMD) {
            checks.append(DiagnosticCheck(
                name: "Przypomnienie w ~/.claude/CLAUDE.md", severity: .warning,
                message: "Starsza wersja bloku (np. z subagentem grunt)",
                detail: ClaudeIntegration.globalInstructionsURL.path, fix: .updateInstructions))
        } else {
            checks.append(DiagnosticCheck(
                name: "Przypomnienie w ~/.claude/CLAUDE.md", severity: .ok, message: "Aktualne",
                detail: ClaudeIntegration.globalInstructionsURL.path))
        }

        // Model na urządzeniu: ostrzeżenie tylko, gdy jest włączony w configu
        let usesOnDevice = config?.providers.contains { $0.kind == .foundation && $0.enabled } ?? false
        switch service.onDevice.availability {
        case .available:
            checks.append(DiagnosticCheck(name: "Model na urządzeniu (Apple)", severity: .ok, message: "Dostępny"))
        case .unavailable(let why):
            checks.append(DiagnosticCheck(
                name: "Model na urządzeniu (Apple)", severity: usesOnDevice ? .warning : .ok,
                message: usesOnDevice ? "Niedostępny: \(why)" : "Niedostępny (\(why)), nieużywany"))
        }

        // Dostawcy
        var needsApproval: [String] = []
        for p in config?.providers ?? [] {
            let base = ProviderDiagnostic(providerID: p.id, kind: p.kind.rawValue, status: "", modelsCount: p.models.count, severity: .ok)
            if !p.enabled {
                providers.append(with(base) { $0.status = "wyłączony" })
                continue
            }
            if case .missingKey(let envName) = service.status(of: p) {
                providers.append(with(base) {
                    $0.status = "brak klucza (\(envName))"
                    $0.keySource = "brak"
                    $0.error = "Brak klucza w Keychain lub .env"
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
                    $0.status = serverAccess == .needsApproval ? "działa, ale serwer zapyta o hasło do klucza" : "gotowy (\(info))"
                    $0.keySource = p.needsKey ? "znaleziony" : "nie wymagany"
                    $0.responseTimeMs = ms
                    $0.severity = serverAccess == .needsApproval ? .warning : .ok
                })
            case .failure(let err):
                providers.append(with(base) {
                    $0.status = "błąd połączenia"
                    $0.responseTimeMs = ms
                    $0.error = err.description
                    $0.severity = .error
                })
            }
        }
        if helper != nil {
            if !needsApproval.isEmpty {
                checks.append(DiagnosticCheck(
                    name: "Dostęp serwera do kluczy", severity: .warning,
                    message: "Serwer zapyta o hasło do Keychain dla: \(needsApproval.joined(separator: ", "))",
                    fix: .authorizeKeys))
            } else if keyAccess != nil {
                checks.append(DiagnosticCheck(name: "Dostęp serwera do kluczy", severity: .ok, message: "Bez pytania o hasło"))
            } else if config?.providers.contains(where: { $0.enabled && $0.needsKey }) == true {
                checks.append(DiagnosticCheck(
                    name: "Dostęp serwera do kluczy", severity: .warning,
                    message: "Nie sprawdzono: podłączony serwer jest starszy niż aplikacja. Przebuduj i zainstaluj aplikację."))
            }
        }

        // Czy Claude w ogóle deleguje
        let week = Calendar.current.date(byAdding: .day, value: -7, to: Date())
        let recent = service.usage.entries(since: week)
        let ok = recent.filter(\.ok).count
        checks.append(DiagnosticCheck(
            name: "Delegowanie w ostatnich 7 dniach",
            severity: recent.isEmpty && anyRegistered ? .warning : .ok,
            message: recent.isEmpty
                ? "Brak wywołań. Zrestartuj Claude po zmianach; instrukcje serwera wczytują się przy starcie sesji."
                : "\(recent.count) wywołań (udanych: \(ok))"))

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
                message: anyRegistered ? "Nie podłączono (opcjonalne)" : "Nie podłączono: Claude nie widzi serwera",
                detail: detail, fix: fix)
        }
        if !FileManager.default.isExecutableFile(atPath: command) {
            return DiagnosticCheck(name: name, severity: .error, message: "Wskazuje nieistniejący plik: \(command)", detail: detail, fix: fix)
        }
        if let helper, command != helper.path {
            return DiagnosticCheck(name: name, severity: .warning, message: "Wskazuje inną binarkę: \(command)", detail: detail, fix: fix)
        }
        return DiagnosticCheck(name: name, severity: .ok, message: "Podłączono (\(command))", detail: detail)
    }

    private func with(_ value: ProviderDiagnostic, _ change: (inout ProviderDiagnostic) -> Void) -> ProviderDiagnostic {
        var copy = value
        change(&copy)
        return copy
    }
}
