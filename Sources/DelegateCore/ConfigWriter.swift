import Foundation

/// Zapis `delegate.toml` z GUI. TOMLKit zamienia znaki spoza ASCII na `\uXXXX` i sortuje klucze
/// alfabetycznie, więc piszemy sami: UTF-8, stała kolejność pól, puste i domyślne wartości pomijamy.
/// Komentarzy z ręcznej edycji nie da się zachować (parser ich nie zwraca); zostaje stały nagłówek.
enum ConfigWriter {
    static let header = """
    # Delegate configuration. Order of [[provider]] = fallback priority.
    # Written by the app: comments added by hand are removed on the next save from the GUI.

    """

    static func write(_ config: Config) -> String {
        var out = header + "\n"
        out += "routing_guidance = \(string(config.routingGuidance, multiline: true))\n"
        out += "timeout_seconds = \(number(config.timeoutSeconds))\n"
        if config.delegationMode != .balanced { out += "delegation_mode = \(string(config.delegationMode.rawValue))\n" }
        if config.personalRegions != Config.defaultPersonalRegions {
            out += "personal_regions = [\(config.personalRegions.map { string($0.rawValue) }.joined(separator: ", "))]\n"
        }
        if let b = config.dailyBudgetUSD { out += "daily_budget_usd = \(number(b))\n" }
        if let n = config.maxParallelAgents { out += "max_parallel_agents = \(n)\n" }
        for p in config.providers {
            out += "\n[[provider]]\n"
            out += "id = \(string(p.id))\n"
            out += "type = \(string(p.kind.rawValue))\n"
            if !p.baseURL.isEmpty { out += "base_url = \(string(p.baseURL))\n" }
            if !p.apiKeyEnv.isEmpty { out += "api_key_env = \(string(p.apiKeyEnv))\n" }
            if !p.enabled { out += "enabled = false\n" }
            if let r = p.privacy { out += "privacy = \(string(r.rawValue))\n" }
            if let t = p.timeoutSeconds { out += "timeout_seconds = \(number(t))\n" }
            if let n = p.note, !n.isEmpty { out += "note = \(string(n, multiline: true))\n" }
            if let g = p.guidance, !g.isEmpty { out += "guidance = \(string(g, multiline: true))\n" }
            for m in p.models {
                out += "\n[[provider.model]]\n"
                out += "id = \(string(m.id))\n"
                if !m.tags.isEmpty { out += "tags = [\(m.tags.map { string($0) }.joined(separator: ", "))]\n" }
                if let c = m.cost { out += "cost = \(string(c))\n" }
                if let v = m.priceIn { out += "price_in = \(number(v))\n" }
                if let v = m.priceOut { out += "price_out = \(number(v))\n" }
                if let n = m.note, !n.isEmpty { out += "note = \(string(n, multiline: true))\n" }
            }
        }
        // Wszystkie wpisy, także same `id`: kolejność `[[agent]]` to priorytet.
        for a in config.agents {
            out += "\n[[agent]]\n"
            out += "id = \(string(a.id))\n"
            if let m = a.model { out += "model = \(string(m))\n" }
            if let e = a.effort { out += "effort = \(string(e))\n" }
            if a.enabled == false { out += "enabled = false\n" }
            if let r = a.privacy { out += "privacy = \(string(r.rawValue))\n" }
            if let g = a.guidance { out += "guidance = \(string(g))\n" }
        }
        for r in config.repos {
            out += "\n[[repo]]\n"
            out += "path = \(string(r.path))\n"
            out += "agents = [\(r.agents.map { string($0) }.joined(separator: ", "))]\n"
        }
        return out
    }

    /// Podstawowy string TOML; z `multiline` tekst z nowymi liniami idzie jako `"""…"""`.
    static func string(_ s: String, multiline: Bool = false) -> String {
        if multiline, s.contains("\n") {
            var body = escape(s, keepNewlines: true)
            // `"""` w treści zamknęłoby string.
            body = body.replacingOccurrences(of: "\"\"\"", with: "\"\"\\\"")
            return "\"\"\"\n\(body)\"\"\""
        }
        return "\"\(escape(s, keepNewlines: false))\""
    }

    private static func escape(_ s: String, keepNewlines: Bool) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += keepNewlines ? "\"" : "\\\""
            case "\n": out += keepNewlines ? "\n" : "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if ch.value < 0x20 || ch.value == 0x7F {
                    out += String(format: "\\u%04X", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out
    }

    /// Liczby całkowite bez `.0`, reszta bez notacji wykładniczej (TOML jej nie lubi z zerem wiodącym).
    static func number(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int(v)) }
        let plain = String(v)
        guard plain.contains("e") else { return plain }
        var s = String(format: "%.12f", v)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }
}
