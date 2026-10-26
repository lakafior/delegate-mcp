import AppKit
import DelegateCore
import Foundation
import ServiceManagement

enum KeySource: Equatable {
    case none, keychain, environment

    var label: String {
        switch self {
        case .none: "brak"
        case .keychain: "w Keychain"
        case .environment: "ze zmiennej / .env"
        }
    }
}

enum IntegrationState: Equatable {
    case notInstalled
    case installed
    /// Wpis istnieje, ale wskazuje inną binarkę (np. aplikację przeniesiono).
    case stale(String)

    var label: String {
        switch self {
        case .notInstalled: "nie zainstalowano"
        case .installed: "zainstalowano"
        case .stale: "wskazuje inną ścieżkę"
        }
    }
}

@MainActor @Observable
final class AppModel {
    let home = DelegateHome.resolve()
    var config = Config()
    var loadError: String?
    var saveError: String?

    private(set) var keySources: [String: KeySource] = [:]
    private(set) var onDevice: OnDeviceAvailability = .unavailable("sprawdzam")
    var testResults: [String: Result<String, DelegateError>] = [:]
    var testing: Set<String> = []

    private(set) var desktopState: IntegrationState = .notInstalled
    private(set) var codeState: IntegrationState = .notInstalled
    private(set) var instructionsInstalled = false
    private(set) var instructionsOutdated = false
    var integrationMessage: String?

    private var saved = Config()
    private var saveTask: Task<Void, Never>?
    private var configModified: Date?
    private let keychain = KeychainSecretStore()
    private let device = FoundationOnDeviceModel()

    init() {
        load()
        refresh()
        migrateKeychainAccessIfNeeded()
    }

    // MARK: config

    func load() {
        do {
            config = try home.loadConfig()
            saved = config
            configModified = modificationDate()
            loadError = nil
        } catch {
            loadError = "Nie można wczytać \(home.configURL.lastPathComponent): \(error)"
        }
    }

    /// Wczytaj ponownie, jeśli plik zmieniono poza aplikacją (i nie mamy niezapisanych zmian).
    func reloadIfChangedOnDisk() {
        guard config == saved, modificationDate() != configModified else { return }
        load()
        refresh()
    }

    func configChanged() {
        guard config != saved else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            try home.save(config)
            saved = config
            configModified = modificationDate()
            saveError = nil
        } catch {
            saveError = "Zapis nie powiódł się: \(error)"
        }
        refresh()
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: home.configURL.path))?[.modificationDate] as? Date
    }

    // MARK: statusy i klucze

    func refresh() {
        let env = EnvSecretStore(dotEnv: home.envURL)
        var sources: [String: KeySource] = [:]
        for p in config.providers where p.needsKey {
            // Tylko sprawdzenie istnienia: odświeżanie widoku nie może wywoływać okna z hasłem.
            if keychain.hasSecret(for: p.apiKeyEnv) { sources[p.apiKeyEnv] = .keychain }
            else if env.hasSecret(for: p.apiKeyEnv) { sources[p.apiKeyEnv] = .environment }
        }
        keySources = sources
        onDevice = device.availability
        refreshIntegrations()
    }

    func keySource(for p: ProviderConfig) -> KeySource { keySources[p.apiKeyEnv] ?? .none }

    func status(of p: ProviderConfig) -> ProviderStatus {
        ProviderStatus.evaluate(p, hasKey: keySource(for: p) != .none, onDevice: onDevice)
    }

    func setKey(_ value: String, for p: ProviderConfig) {
        do {
            try keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: p.apiKeyEnv,
                             trusting: trustedHelperPaths)
            saveError = nil
        } catch {
            saveError = "Keychain: \(error)"
        }
        refresh()
    }

    /// Serwer MCP musi czytać klucze bez pytania o hasło (uruchamia go Claude, nie my).
    private var trustedHelperPaths: [String] { helperExists ? [helperURL.path] : [] }

    private static let aclVersionKey = "keychainACLVersion"
    private static let currentACLVersion = 1

    /// Jednorazowo przepisuje istniejące klucze z listą zaufanych programów (po aktualizacji aplikacji).
    private func migrateKeychainAccessIfNeeded() {
        guard UserDefaults.standard.integer(forKey: Self.aclVersionKey) < Self.currentACLVersion, helperExists else { return }
        if reauthorizeKeys() { UserDefaults.standard.set(Self.currentACLVersion, forKey: Self.aclVersionKey) }
    }

    /// Przepisuje wszystkie klucze z Keychain tak, by serwer czytał je bez pytania. Zwraca `true`, gdy się udało.
    @discardableResult
    func reauthorizeKeys() -> Bool {
        var ok = true
        var count = 0
        for p in config.providers where p.needsKey {
            guard let value = keychain.secret(for: p.apiKeyEnv) else { continue }
            do {
                try keychain.set(value, for: p.apiKeyEnv, trusting: trustedHelperPaths)
                count += 1
            } catch {
                ok = false
                saveError = "Keychain: \(error)"
            }
        }
        integrationMessage = ok ? "Serwer ma dostęp do kluczy (\(count)) bez pytania o hasło." : integrationMessage
        refresh()
        return ok
    }

    func removeKey(for p: ProviderConfig) {
        do { try keychain.remove(p.apiKeyEnv) } catch { saveError = "Keychain: \(error)" }
        refresh()
    }

    /// Klucz w Keychain jest zapisany pod nazwą `api_key_env`; przy jej zmianie przenosimy wpis,
    /// żeby nie „zgubić” klucza. Istniejącego wpisu pod nową nazwą nie nadpisujemy, a starego
    /// nie kasujemy, jeśli używa go inny dostawca.
    private func moveKey(from oldName: String, to newName: String) {
        let old = oldName.trimmingCharacters(in: .whitespaces)
        let new = newName.trimmingCharacters(in: .whitespaces)
        guard old != new, !old.isEmpty, let value = keychain.secret(for: old) else { return }
        do {
            if !new.isEmpty, !keychain.hasSecret(for: new) {
                try keychain.set(value, for: new, trusting: trustedHelperPaths)
            }
            if !config.providers.contains(where: { $0.apiKeyEnv == old }) {
                try keychain.remove(old)
            }
        } catch {
            saveError = "Keychain: \(error)"
        }
    }

    /// Zmiana nazwy klucza z formularza (zatwierdzana, nie przy każdym znaku).
    func setKeyEnv(_ rawName: String, forProvider id: String) {
        guard let idx = config.providers.firstIndex(where: { $0.id == id }) else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = config.providers[idx].apiKeyEnv
        guard name != old else { return }
        config.providers[idx].apiKeyEnv = name
        moveKey(from: old, to: name)
        configChanged()
        refresh()
    }

    func test(_ p: ProviderConfig) {
        testing.insert(p.id)
        testResults[p.id] = nil
        let service = DelegateService(home: home)
        Task {
            let result = await service.test(p)
            testResults[p.id] = result
            testing.remove(p.id)
        }
    }

    var isTestingAny: Bool { !testing.isEmpty }

    func testAll() {
        for p in config.providers where p.enabled {
            test(p)
        }
    }

    func modelInfos(for p: ProviderConfig) async throws -> [ModelInfo] {
        try await DelegateService(home: home).modelInfos(for: p)
    }

    // MARK: edycja listy dostawców

    func addProvider(from preset: ProviderPreset) -> String {
        let id = config.addProvider(from: preset)
        refresh()
        return id
    }

    @discardableResult
    func renameProvider(from oldId: String, to rawNewId: String) -> Bool {
        let trimmed = rawNewId.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldEnv = config.providers.first { $0.id == oldId }?.apiKeyEnv
        guard config.renameProvider(from: oldId, to: rawNewId) else { return false }
        if let oldEnv, let newEnv = config.providers.first(where: { $0.id == trimmed })?.apiKeyEnv {
            moveKey(from: oldEnv, to: newEnv)
        }
        if let res = testResults.removeValue(forKey: oldId) {
            testResults[trimmed] = res
        }
        testing.remove(oldId)
        configChanged()
        refresh()
        return true
    }

    /// Usuwa dostawcę razem z jego kluczem w Keychain (o ile inny dostawca go nie używa).
    func removeProvider(id: String) {
        guard let p = config.providers.first(where: { $0.id == id }) else { return }
        config.providers.removeAll { $0.id == id }
        testResults[id] = nil
        if p.needsKey, !config.providers.contains(where: { $0.apiKeyEnv == p.apiKeyEnv }) {
            do { try keychain.remove(p.apiKeyEnv) } catch { saveError = "Keychain: \(error)" }
        }
        refresh()
    }

    // MARK: użycie

    func usage(days: Int) -> [UsageEntry] {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        return UsageLog(url: home.usageURL).entries(since: since)
    }

    var callsToday: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return UsageLog(url: home.usageURL).entries(since: start).count
    }

    var costToday: Double {
        let start = Calendar.current.startOfDay(for: Date())
        return UsageLog(url: home.usageURL).entries(since: start).compactMap(\.costUSD).reduce(0, +)
    }

    private static let showCostInMenuBarKey = "showCostInMenuBar"
    var showCostInMenuBar: Bool {
        get { UserDefaults.standard.bool(forKey: Self.showCostInMenuBarKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.showCostInMenuBarKey)
            refresh()
        }
    }

    /// Ostrzeżenie w pasku menu: tylko to, co użytkownik może naprawić (brak klucza, nieudany test).
    /// Niedostępny model na urządzeniu to stan sprzętu, nie błąd konfiguracji.
    var hasProviderIssues: Bool {
        config.providers.contains { p in
            guard p.enabled else { return false }
            if case .failure = testResults[p.id] { return true }
            if case .missingKey = status(of: p) { return true }
            return false
        }
    }

    // MARK: start przy logowaniu

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                saveError = "Start przy logowaniu: \(error.localizedDescription)"
            }
        }
    }

    // MARK: integracja z Claude

    /// Binarka serwera: w .app w `Contents/Helpers`, przy `swift run` obok pliku wykonywalnego.
    var helperURL: URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/delegate-mcp")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("delegate-mcp")
    }

    var helperExists: Bool { FileManager.default.isExecutableFile(atPath: helperURL.path) }

    private func state(for command: String?) -> IntegrationState {
        guard let command else { return .notInstalled }
        return command == helperURL.path ? .installed : .stale(command)
    }

    func refreshIntegrations() {
        let desktop = try? Data(contentsOf: ClaudeIntegration.desktopConfigURL)
        desktopState = state(for: ClaudeIntegration.registeredCommand(in: desktop))
        let code = try? Data(contentsOf: ClaudeIntegration.claudeCodeConfigURL)
        codeState = state(for: ClaudeIntegration.registeredCommand(in: code))
        let text = (try? String(contentsOf: ClaudeIntegration.globalInstructionsURL, encoding: .utf8)) ?? ""
        instructionsInstalled = ClaudeIntegration.hasInstructions(text)
        instructionsOutdated = instructionsInstalled && !ClaudeIntegration.instructionsUpToDate(text)
    }

    func installDesktop(_ install: Bool) {
        let url = ClaudeIntegration.desktopConfigURL
        do {
            let existing = try? Data(contentsOf: url)
            if let existing { try existing.write(to: url.appendingPathExtension("bak")) }
            let updated = try ClaudeIntegration.updatingDesktopConfig(existing, command: install ? helperURL.path : nil)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try updated.write(to: url, options: .atomic)
            integrationMessage = install ? "Dodano do Claude Desktop. Uruchom go ponownie." : "Usunięto z Claude Desktop. Uruchom go ponownie."
        } catch {
            integrationMessage = "Claude Desktop: \(error)"
        }
        refreshIntegrations()
    }

    func installCode(_ install: Bool) {
        let path = helperURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let name = ClaudeIntegration.serverName
        let command = install
            ? "claude mcp remove \(name) -s user >/dev/null 2>&1; claude mcp add \(name) -s user -- '\(path)'"
            : "claude mcp remove \(name) -s user"
        integrationMessage = "Uruchamiam claude…"
        Task {
            let result = await Self.runShell(command)
            integrationMessage = result.status == 0
                ? (install ? "Dodano do Claude Code." : "Usunięto z Claude Code.")
                : "Claude Code: \(result.output.isEmpty ? "błąd \(result.status) (czy `claude` jest w PATH?)" : result.output)"
            refreshIntegrations()
        }
    }

    func installInstructions(_ install: Bool) {
        let url = ClaudeIntegration.globalInstructionsURL
        do {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let updated = install ? ClaudeIntegration.addingInstructions(to: text) : ClaudeIntegration.removingInstructions(from: text)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try updated.write(to: url, atomically: true, encoding: .utf8)
            integrationMessage = install ? "Zapisano blok „Delegowanie i tańsze modele” w ~/.claude/CLAUDE.md." : "Usunięto blok z ~/.claude/CLAUDE.md."
        } catch {
            integrationMessage = "CLAUDE.md: \(error)"
        }
        refreshIntegrations()
    }

    nonisolated private static func runShell(_ command: String) async -> (status: Int32, output: String) {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { return (-1, "\(error)") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }
}
