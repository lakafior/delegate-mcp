import Foundation

/// Jeden licznik z nagłówków `x-ratelimit-remaining-<nazwa>` / `x-ratelimit-reset-<nazwa>` (Groq, SambaNova,
/// OpenAI i inne API zgodne z OpenAI). Przerwy w `ModelCooldowns` zakładamy dopiero po 429; z tych nagłówków
/// widać wyczerpany limit wcześniej, więc model odpada przed odmową, a nie po nieudanej próbie.
public struct RateLimit: Sendable, Equatable {
    /// Końcówka nazwy nagłówka, np. `requests`, `tokens`, `requests-day`.
    public var name: String
    public var remaining: Int
    /// Sekundy do odnowienia; `nil`, gdy dostawca nie podaje `x-ratelimit-reset-<nazwa>`.
    public var reset: TimeInterval?

    public init(name: String, remaining: Int, reset: TimeInterval? = nil) {
        self.name = name
        self.remaining = remaining
        self.reset = reset
    }

    static let remainingPrefix = "x-ratelimit-remaining-"
    static let resetPrefix = "x-ratelimit-reset-"

    var isTokens: Bool { name.contains("token") }

    public static func parse(_ headers: [AnyHashable: Any], now: Date = Date()) -> [RateLimit] {
        var lower: [String: String] = [:]
        for (key, value) in headers {
            guard let key = key as? String else { continue }
            lower[key.lowercased()] = "\(value)".trimmingCharacters(in: .whitespaces)
        }
        return lower.compactMap { key, value -> RateLimit? in
            guard key.hasPrefix(remainingPrefix), let remaining = Int(value) else { return nil }
            let name = String(key.dropFirst(remainingPrefix.count))
            return RateLimit(name: name, remaining: remaining,
                             reset: lower[resetPrefix + name].flatMap { duration($0, now: now) })
        }.sorted { $0.name < $1.name }
    }

    /// `2m59.56s`, `7.66s`, `120ms`, `1h2m` albo same sekundy; liczba wyglądająca na czas uniksowy = moment odnowienia.
    static func duration(_ text: String, now: Date = Date()) -> TimeInterval? {
        let s = text.lowercased()
        if let plain = Double(s) {
            return plain > 1_000_000_000 ? max(0, plain - now.timeIntervalSince1970) : plain
        }
        var total: TimeInterval = 0
        var number = ""
        var found = false
        var chars = Array(s)[...]
        while let ch = chars.popFirst() {
            if ch.isNumber || ch == "." { number.append(ch); continue }
            guard let value = Double(number) else { return nil }
            number = ""
            switch ch {
            case "h": total += value * 3600
            case "m" where chars.first == "s":
                chars.removeFirst()
                total += value / 1000
            case "m": total += value * 60
            case "s": total += value
            default: return nil
            }
            found = true
        }
        return found && number.isEmpty ? total : nil
    }

    /// Przerwa, zanim dostawca odmówi: licznik spadł do zera albo tokenów zostało mniej, niż zużyło ostatnie
    /// zapytanie (następne podobne by nie weszło). Najdłuższa z pasujących, od 1 s do doby.
    public static func pause(_ limits: [RateLimit], usedTokens: Int?) -> (seconds: TimeInterval, reason: String)? {
        let hits: [(TimeInterval, String)] = limits.compactMap { l in
            let wait = l.reset ?? (l.name.contains("day") || l.name.contains("month") ? 3600 : 60)
            if l.remaining <= 0 {
                return (wait, "rate limit reached (\(remainingPrefix)\(l.name): 0)")
            }
            if l.isTokens, let used = usedTokens, used > 0, l.remaining < used {
                return (wait, "rate limit nearly used (\(l.remaining) \(l.name) left, the last request took \(used))")
            }
            return nil
        }
        guard let worst = hits.max(by: { $0.0 < $1.0 }) else { return nil }
        return (min(max(worst.0, 1), 24 * 3600), worst.1)
    }
}
