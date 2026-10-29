import Foundation

/// Wydanie aplikacji z GitHub Releases.
public struct AppRelease: Sendable, Equatable {
    public var version: String
    public var notes: String
    public var pageURL: URL
    /// `Delegate-<wersja>.dmg`, jeśli workflow go dołączył.
    public var dmgURL: URL?
}

/// Sprawdza najnowsze wydanie (`releases/latest` pomija szkice i prerelease'y). Bez pobierania i instalacji:
/// aplikacja tylko pokazuje, że jest nowsza wersja, i otwiera DMG w przeglądarce.
public struct UpdateChecker: Sendable {
    public static let repository = "lakafior/delegate-mcp"
    let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// Najnowsze wydanie, jeśli jest nowsze niż `current`; `nil`, gdy aplikacja jest aktualna.
    public func newerRelease(than current: String) async throws -> AppRelease? {
        let release = try await latest()
        return Self.isVersion(release.version, newerThan: current) ? release : nil
    }

    public func latest() async throws -> AppRelease {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!,
                             timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Delegate-update-check", forHTTPHeaderField: "User-Agent")
        let (data, http) = try await transport.send(req)
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(status: http.statusCode, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> AppRelease {
        struct Asset: Decodable { var name: String; var browser_download_url: URL }
        struct Release: Decodable { var tag_name: String; var html_url: URL; var body: String?; var assets: [Asset]? }
        guard let r = try? JSONDecoder().decode(Release.self, from: data) else {
            throw ProviderError.badResponse("unexpected GitHub release JSON")
        }
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        let dmg = r.assets?.first { $0.name.hasSuffix(".dmg") }?.browser_download_url
        return AppRelease(version: version, notes: r.body ?? "", pageURL: r.html_url, dmgURL: dmg)
    }

    /// Porównanie liczbowe po kropkach (`0.10.0` > `0.9.1`); brakujące części to 0, przyrostki po `-` pomijamy.
    public static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let core = v.split(separator: "-").first.map(String.init) ?? v
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
