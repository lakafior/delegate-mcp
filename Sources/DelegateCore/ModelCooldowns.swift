import Foundation

/// Przerwy dla modeli, które właśnie odmówiły (429, 503, model nieobsługiwany…). Router je pomija,
/// zamiast przy każdym wywołaniu tracić czas z limitu na model, który i tak nie odpowie.
/// Plik JSON (`model_cooldowns.json`) dzielą wszystkie procesy serwera, czyli wszystkie sesje Claude'a.
public struct ModelCooldown: Codable, Sendable, Equatable {
    public var until: Date
    public var reason: String

    public init(until: Date, reason: String) {
        self.until = until
        self.reason = reason
    }
}

public struct ModelCooldowns: Sendable {
    /// `nil` = tylko w pamięci (testy i serwisy bez katalogu domowego).
    let url: URL?
    private let memory = MemoryBox()

    public init(url: URL?) { self.url = url }

    /// Aktywne przerwy, klucz `provider/model`.
    public func active(now: Date = Date()) -> [String: ModelCooldown] {
        load().filter { $0.value.until > now }
    }

    public func set(_ ref: String, _ cooldown: ModelCooldown, now: Date = Date()) {
        var all = active(now: now)
        all[ref] = cooldown
        save(all)
    }

    public func clear(_ ref: String? = nil, now: Date = Date()) {
        var all = active(now: now)
        guard ref == nil || all[ref!] != nil else { return }
        if let ref { all.removeValue(forKey: ref) } else { all = [:] }
        save(all)
    }

    // MARK: klasyfikacja błędów

    /// Jak długo omijać model po tym błędzie; `nil` = błąd nie mówi nic trwałego o modelu.
    /// `fullTimeout`: próba dostała uczciwą szansę: pełny czas albo co najmniej `fairTimeout`.
    public static func cooldown(for error: Error, fullTimeout: Bool = true) -> (seconds: TimeInterval, reason: String)? {
        guard let e = error as? ProviderError else { return nil }
        switch e {
        case .http(let status, let body):
            let lower = body.lowercased()
            switch status {
            case 429:
                if lower.contains("limit: 0") {
                    return (day, "no quota for this model on the current plan (HTTP 429, limit 0)")
                }
                if let wait = retryDelay(in: body) {
                    return (min(max(wait, 30), day), "quota exhausted (HTTP 429)")
                }
                return (60, "rate limited (HTTP 429)")
            case 402:
                return (3600, "out of credit (HTTP 402)")
            case 404:
                return (week, "model not found (HTTP 404); remove it from delegate.toml")
            case 400 where unsupportedMarkers.contains(where: lower.contains):
                return (week, "model rejects chat requests (HTTP 400: \(body.prefix(80))); remove it from delegate.toml")
            case 500:
                return (120, "provider error (HTTP 500)")
            case 502, 503, 504, 529:
                return (300, "overloaded (HTTP \(status))")
            default:
                return nil
            }
        case .network(let m) where fullTimeout && m.lowercased().contains("timed out"):
            return (300, "no reply before the timeout")
        default:
            return nil
        }
    }

    /// Tyle milczenia wystarczy, żeby uznać model za zawieszony, nawet gdy limit wywołania synchronicznego
    /// przyciął mu czas (inaczej zawieszony model w wywołaniach synchronicznych nigdy nie dostałby przerwy).
    public static let fairTimeout: TimeInterval = 25

    static let day: TimeInterval = 24 * 3600
    static let week: TimeInterval = 7 * day
    static let unsupportedMarkers = ["only supports", "not supported", "is not found", "does not exist", "model_not_found", "unknown model"]

    /// „Please retry in 22h54m51.6s” (Gemini) albo „retry after 30 seconds”.
    static func retryDelay(in body: String) -> TimeInterval? {
        let lower = body.lowercased()
        guard let range = lower.range(of: "retry in ") ?? lower.range(of: "retry after ") else { return nil }
        let rest = lower[range.upperBound...].prefix(40)
        var total: TimeInterval = 0
        var number = ""
        var found = false
        scan: for ch in rest {
            if ch.isNumber || ch == "." { number.append(ch); continue }
            if ch == " " { continue }
            guard let value = Double(number) else { break }
            switch ch {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: break scan
            }
            found = true
            number = ""
        }
        return found ? total : nil
    }

    // MARK: zapis

    private func load() -> [String: ModelCooldown] {
        guard let url else { return memory.value }
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: ModelCooldown].self, from: data)) ?? [:]
    }

    private func save(_ all: [String: ModelCooldown]) {
        guard let url else { memory.value = all; return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(all).write(to: url, options: .atomic)
    }
}

/// Stan w pamięci dla `ModelCooldowns(url: nil)`.
private final class MemoryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: [String: ModelCooldown] = [:]
    var value: [String: ModelCooldown] {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Przerwy dla agentów ACP: ten sam plik co modele (`ModelCooldowns`), klucz `agent:<id>`.
public enum AgentPause {
    public static func key(_ agentID: String) -> String { "agent:\(agentID)" }

    public enum Kind: Sendable, Equatable {
        /// Agent nie jest zalogowany: przerwa do zalogowania w apce (sprawdzenie zdejmuje ją wcześniej).
        case signIn
        /// Limit planu albo zapytań: do resetu, jeśli agent go podał, inaczej godzina.
        case limit
        /// Drugi z rzędu limit czasu albo zawieszenie.
        case timeouts
    }

    /// Przerwa po nieudanym zadaniu. `previousError`: błąd poprzedniego zadania tego agenta z logu (`nil` = udane
    /// albo żadnego), do reguły „dwa razy z rzędu”. Patrzymy tylko na pierwszą linię: dalej bywa częściowy raport.
    public static func pause(after error: String, previousError: String?) -> (seconds: TimeInterval, reason: String, kind: Kind)? {
        let line = firstLine(error)
        if ["isn't signed in", "not signed in", "authentication required"].contains(where: line.contains) {
            return (ModelCooldowns.week, "not signed in (the user signs in in the Delegate app)", .signIn)
        }
        if limitMarkers.contains(where: line.contains) {
            let wait = ModelCooldowns.retryDelay(in: error).map { min(max($0, 60), ModelCooldowns.day) } ?? 3600
            return (wait, "plan or rate limit reached", .limit)
        }
        if isTimeLimit(line), let previousError, isTimeLimit(firstLine(previousError)) {
            return (3600, "timed out or stopped responding twice in a row", .timeouts)
        }
        return nil
    }

    static let limitMarkers = ["usage limit", "rate limit", "quota", "limit reached", "too many requests", "429",
                               "out of credits", "credit balance", "resource_exhausted"]

    static func firstLine(_ text: String) -> String { String(text.prefix { $0 != "\n" }).lowercased() }
    static func isTimeLimit(_ line: String) -> Bool { line.contains("didn't finish in") || line.contains("stopped responding") }
}
