import Foundation

/// Ostatnie sprawdzenie agenta zapisane na dysk (`agents/checks.json`). Apka zapisuje je po każdym sprawdzeniu,
/// serwer czyta przy `list_models`, żeby dyrygent znał modele i poziomy wysiłku agentów bez ich uruchamiania.
public struct AgentCheckRecord: Codable, Sendable, Equatable {
    /// `signedIn`, `needsSignIn` albo `failed`.
    public var status: String
    public var models: [String]
    public var defaultModel: String?
    public var efforts: [String]
    public var defaultEffort: String?
    public var checkedAt: Date

    public init(_ check: AgentAccount.Check, at date: Date = Date()) {
        status = switch check.signIn {
        case .signedIn: "signedIn"
        case .needsSignIn: "needsSignIn"
        case .failed: "failed"
        }
        models = check.models
        defaultModel = check.defaultModel
        efforts = check.efforts
        defaultEffort = check.defaultEffort
        checkedAt = date
    }
}

public struct AgentCheckCache: Sendable {
    let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> [String: AgentCheckRecord] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: AgentCheckRecord].self, from: data)) ?? [:]
    }

    public func save(_ id: String, _ record: AgentCheckRecord?) {
        var all = load()
        all[id] = record
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(all).write(to: url, options: .atomic)
    }
}

extension DelegateHome {
    public var agentChecksURL: URL { agentsURL.appendingPathComponent("checks.json") }
}

/// Opis agentów dla dyrygenta (sekcja `list_models`): kto jest dostępny, gdzie idą dane, jakie modele i wysiłek.
public enum AgentCatalog {
    /// Bez `default` (to „brak wyboru”) i bez powtórzeń (Copilot ogłasza `auto` dwa razy).
    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { $0 != "default" && seen.insert($0).inserted }
    }

    public static func describe(installed: [InstalledAgent], config: Config, checks: [String: AgentCheckRecord]) -> String {
        guard !installed.isEmpty else { return "" }
        var out = "\n## Agents (delegate_agent)\n\n"
        for agent in installed.sorted(by: { $0.id < $1.id }) {
            let settings = config.agentSettings(agent.id)
            let region = AgentRegions.region(for: agent.id, config: config)
            var line = "- `\(agent.id)` (\(agent.name)) · region \(region.rawValue)"
            if settings?.isEnabled == false {
                out += line + " · turned off by the user\n"
                continue
            }
            let check = checks[agent.id]
            switch check?.status {
            case "needsSignIn": line += " · NOT signed in (the user must sign in in the Delegate app)"
            case "failed": line += " · last check failed"
            case nil: line += " · not checked yet"
            default: break
            }
            out += line + "\n"
            if let check, !check.models.isEmpty {
                let chosen = settings?.model ?? check.defaultModel
                out += "  models: " + unique(check.models).joined(separator: ", ")
                out += chosen.map { " (default: \($0))" } ?? ""
                out += "\n"
            }
            if let check, !check.efforts.isEmpty {
                let chosen = settings?.effort ?? check.defaultEffort
                out += "  effort: " + unique(check.efforts).joined(separator: ", ")
                out += chosen.map { " (default: \($0))" } ?? ""
                out += "\n"
            }
        }
        let rules = config.repos
        if !rules.isEmpty {
            out += "\nRepository rules: " + rules.map { r in
                "\(r.path) → " + (r.agents.isEmpty ? "no agents" : r.agents.joined(separator: ", "))
            }.joined(separator: "; ") + "\n"
        }
        return out
    }
}
