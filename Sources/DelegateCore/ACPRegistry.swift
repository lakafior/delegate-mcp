import Foundation

/// Publiczny rejestr agentów ACP (wspólny dla Zeda i IDE JetBrains). Wpis mówi, jak agenta pobrać:
/// `binary` (archiwum per platforma z sumą SHA-256), `npx` (paczka npm, potrzebny Node) albo `uvx` (Python, potrzebny uv).
public struct ACPRegistry: Codable, Sendable, Equatable {
    public static let sourceURL = URL(string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json")!

    public var version: String
    public var agents: [Agent]

    public struct Agent: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var version: String
        public var description: String?
        public var repository: String?
        public var website: String?
        public var authors: [String]?
        public var license: String?
        public var icon: String?
        public var distribution: Distribution
    }

    public struct Distribution: Codable, Sendable, Equatable {
        public var binary: [String: BinaryTarget]?
        public var npx: PackageTarget?
        public var uvx: PackageTarget?
    }

    public struct BinaryTarget: Codable, Sendable, Equatable {
        public var archive: String
        public var sha256: String?
        public var cmd: String
        public var args: [String]?
        public var env: [String: String]?
    }

    public struct PackageTarget: Codable, Sendable, Equatable {
        public var package: String
        public var args: [String]?
        public var env: [String: String]?
    }

    public static func parse(_ data: Data) throws -> ACPRegistry {
        do {
            return try JSONDecoder().decode(ACPRegistry.self, from: data)
        } catch {
            throw DelegateError(description: "ACP registry: unreadable index (\(error))")
        }
    }

    /// Klucz platformy w `distribution.binary`.
    public static var platformKey: String {
        #if arch(arm64)
        "darwin-aarch64"
        #else
        "darwin-x86_64"
        #endif
    }

    public func agent(_ id: String) -> Agent? { agents.first { $0.id == id } }
}

extension ACPRegistry.Agent {
    /// Jak da się zainstalować agenta na tym Macu: binarka, paczka npm (systemowy Node) albo jeszcze nie.
    public enum InstallKind: Sendable, Equatable {
        case binary(ACPRegistry.BinaryTarget)
        case npm(ACPRegistry.PackageTarget)
        /// Wymaga narzędzia, którego jeszcze nie obsługujemy (`uv` dla uvx).
        case needsRuntime(String)
        case unavailable
    }

    public var installKind: InstallKind {
        if let target = distribution.binary?[ACPRegistry.platformKey] { return .binary(target) }
        if let npx = distribution.npx { return .npm(npx) }
        if distribution.uvx != nil { return .needsRuntime("uv") }
        return .unavailable
    }
}

/// Lokalna kopia rejestru (`agents/registry.json`), odświeżana najwyżej raz na `maxAge`. Bez sieci: stara kopia.
public struct ACPRegistryStore: Sendable {
    let cacheURL: URL
    let transport: any HTTPTransport
    let maxAge: TimeInterval

    public init(cacheURL: URL, transport: any HTTPTransport = URLSessionTransport(), maxAge: TimeInterval = 24 * 3600) {
        self.cacheURL = cacheURL
        self.transport = transport
        self.maxAge = maxAge
    }

    public var cacheDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
    }

    /// `nil`, gdy nie ma ani świeżego pobrania, ani kopii.
    public func load(forceRefresh: Bool = false) async -> ACPRegistry? {
        if !forceRefresh, let date = cacheDate, Date().timeIntervalSince(date) < maxAge, let cached = readCache() {
            return cached
        }
        if let fresh = await download() { return fresh }
        return readCache()
    }

    private func readCache() -> ACPRegistry? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? ACPRegistry.parse(data)
    }

    private func download() async -> ACPRegistry? {
        var req = URLRequest(url: ACPRegistry.sourceURL, timeoutInterval: 30)
        req.httpMethod = "GET"
        guard let (data, http) = try? await transport.send(req), (200..<300).contains(http.statusCode),
              let registry = try? ACPRegistry.parse(data) else { return nil }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
        return registry
    }
}
