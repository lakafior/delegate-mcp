import Foundation
import Security

public protocol SecretStore: Sendable {
    func secret(for name: String) -> String?
}

/// Zmienne środowiska, potem plik `.env` (awaryjnie, jak w oryginalnym planie).
public struct EnvSecretStore: SecretStore {
    let environment: [String: String]
    let dotEnv: URL?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, dotEnv: URL? = nil) {
        self.environment = environment
        self.dotEnv = dotEnv
    }

    public func secret(for name: String) -> String? {
        if let v = environment[name], !v.isEmpty { return v }
        guard let dotEnv, let text = try? String(contentsOf: dotEnv, encoding: .utf8) else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard key == name else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

/// Klucze w Keychain (generic password: service = `com.mar.delegate`, account = nazwa klucza).
public struct KeychainSecretStore: SecretStore {
    public static let defaultService = "com.mar.delegate"
    let service: String

    public init(service: String = KeychainSecretStore.defaultService) { self.service = service }

    private func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: name]
    }

    public func secret(for name: String) -> String? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    /// Zapisuje klucz tak, żeby wskazane programy (oraz ten proces) czytały go bez pytania o hasło.
    /// Wpis jest zakładany od nowa z listą zaufanych aplikacji (ACL), bo samej listy nie da się
    /// zmienić w istniejącym wpisie bez zgody użytkownika.
    public func set(_ value: String, for name: String, trusting paths: [String]) throws {
        let data = Data(value.utf8)
        var access: SecAccess?
        var apps: [SecTrustedApplication] = []
        var me: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me { apps.append(me) }
        for path in paths {
            var app: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, let app { apps.append(app) }
        }
        let accessStatus = SecAccessCreate(name as CFString, apps as CFArray, &access)
        guard accessStatus == errSecSuccess, let access else { throw KeychainError(status: accessStatus) }

        _ = SecItemDelete(query(name) as CFDictionary)
        var add = query(name)
        add[kSecValueData as String] = data
        add[kSecAttrAccess as String] = access
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            try? set(value, for: name)   // nie zostawiaj użytkownika bez klucza
            throw KeychainError(status: status)
        }
    }

    public func set(_ value: String, for name: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(name)
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func remove(_ name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// Pierwszy store, który zna klucz, wygrywa.
public struct CompositeSecretStore: SecretStore {
    let stores: [any SecretStore]
    public init(_ stores: [any SecretStore]) { self.stores = stores }
    public func secret(for name: String) -> String? {
        for s in stores { if let v = s.secret(for: name) { return v } }
        return nil
    }
}
