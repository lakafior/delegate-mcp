import Foundation

/// Gdzie trafiają dane wysłane do dostawcy. Serwer używa tego do egzekwowania `Sensitivity`.
public enum PrivacyRegion: String, Codable, Sendable, CaseIterable {
    /// Na tym Macu (model Apple, Ollama, LM Studio).
    case local
    case eu
    case us
    case cn
    /// Nieznany dostawca: dopóki użytkownik nie ustawi regionu, nie dostaje danych osobistych.
    case other

    /// Domyślne porty serwerów modeli na tym Macu (Ollama, LM Studio).
    static let localModelPorts: Set<Int> = [11434, 1234]

    /// Region z typu i hosta `base_url`. Jawne `privacy` w configu ma pierwszeństwo.
    /// Adres lokalny to jeszcze nie model lokalny: gateway (OmniRoute, LiteLLM) też słucha na localhost i wysyła
    /// dane do chmury, więc `local` dostają tylko domyślne porty Ollamy i LM Studio, reszta jest `other`.
    public static func inferred(for p: ProviderConfig) -> PrivacyRegion {
        if p.kind == .foundation { return .local }
        guard let url = URL(string: p.baseURL), let host = url.host?.lowercased() else { return .other }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") {
            return url.port.map(localModelPorts.contains) == true ? .local : .other
        }
        func matches(_ domains: [String]) -> Bool { domains.contains { host == $0 || host.hasSuffix("." + $0) } }
        if matches(["mistral.ai"]) { return .eu }
        if matches(["deepseek.com"]) { return .cn }
        if matches(["googleapis.com", "openai.com", "anthropic.com", "openrouter.ai", "venice.ai", "aionlabs.ai",
                    "x.ai", "groq.com", "together.xyz", "perplexity.ai", "nvidia.com", "sambanova.ai",
                    "cloudflare.com"]) { return .us }
        return .other
    }
}

/// Jak wrażliwe są dane w zadaniu; Claude ustawia to w `delegate`, serwer pilnuje dostawców.
public enum Sensitivity: String, Codable, Sendable, CaseIterable {
    /// Nic osobistego: każdy gotowy dostawca.
    case `public`
    /// Dane osobiste albo z pracy (bez sekretów): tylko regiony z `Config.personalRegions`.
    case personal
    /// Ma nie opuszczać Maca: tylko dostawcy lokalni.
    case `private`
}

/// Jak chętnie Claude ma delegować; zmienia ton instrukcji serwera.
public enum DelegationMode: String, Codable, Sendable, CaseIterable {
    case conservative, balanced, aggressive
}

extension ProviderConfig {
    /// Region z configu albo wywnioskowany z adresu.
    public var effectivePrivacy: PrivacyRegion { privacy ?? PrivacyRegion.inferred(for: self) }
}

extension ModelConfig {
    /// Czy wywołanie nic nie kosztuje (dla dziennego budżetu). Nieznana cena liczy się jako płatna.
    public func isFree(at provider: ProviderConfig) -> Bool {
        if provider.effectivePrivacy == .local { return true }
        if cost == "free" { return true }
        if priceIn != nil || priceOut != nil { return (priceIn ?? 0) == 0 && (priceOut ?? 0) == 0 }
        return false
    }
}

/// Dlaczego dostawca albo model odpadł z kolejki (do podglądu w GUI i komunikatów błędów).
public struct RoutingExclusion: Sendable, Equatable {
    public enum Kind: Sendable {
        /// Brak klucza albo dostawca wyłączony.
        case unavailable
        /// Region danych nie pasuje do `sensitivity`.
        case region
        /// Przerwa po błędzie (`ModelCooldowns`).
        case pause
        /// Dzienny budżet wydany, a model jest płatny.
        case budget
    }

    public var ref: String
    public var reason: String
    public var kind: Kind

    public init(ref: String, reason: String, kind: Kind) {
        self.ref = ref
        self.reason = reason
        self.kind = kind
    }

    static let pausePrefix = "paused until"
    /// Model pominięty, bo ma przerwę po błędzie (`ModelCooldowns`).
    public var isPause: Bool { kind == .pause }
}

/// Co serwer zrobiłby z zadaniem: kolejność prób i co pominął.
public struct RoutingPlan: Sendable {
    public var candidates: [Candidate]
    public var excluded: [RoutingExclusion]
    /// Wydane dziś na płatne modele (z logu), gdy ustawiono budżet.
    public var spentToday: Double?

    /// Co Claude ma zrobić, gdy routing nikogo nie zostawił: po linii na każdy powód odmowy, na końcu „zrób sam”.
    /// Odmowa bez wskazówki kończy się zwykle ponowieniem tego samego wywołania.
    public func refusalAdvice(for request: DelegateRequest, config: Config) -> [String] {
        var relevant = excluded
        let pinned = request.model.map { !$0.isEmpty && !request.allowFallback } ?? false
        if pinned, let m = request.model {
            // Bez fallbacku liczą się tylko powody, dla których odpadł wskazany model, nie cały katalog.
            relevant = excluded.filter { e in
                e.ref == m || m.hasPrefix(e.ref + "/") || e.ref.hasSuffix("/" + m)
                    || config.providers.contains { $0.id == e.ref && $0.models.contains { $0.id == m } }
            }
        }
        let kinds = Set(relevant.map(\.kind))
        var out: [String] = []
        if pinned, let m = request.model {
            let known = config.providers.contains { p in p.models.contains { "\(p.id)/\($0.id)" == m || $0.id == m } }
            out.append(known
                ? "Pick another model from list_models, or drop fallback = false so the server can route around \"\(m)\"."
                : "\"\(m)\" is not in the catalog: pick a model from list_models, or omit `model` to route automatically.")
        }
        if kinds.contains(.region) {
            switch request.sensitivity {
            case .private:
                out.append("Private tasks run only on local models and none is ready (the user can add Ollama, LM Studio or Apple on-device in the Delegate app). Lower `sensitivity` only if the content really allows it.")
            case .personal:
                let regions = config.personalRegions.map(\.rawValue).sorted().joined(separator: ", ")
                out.append("Personal data goes only to regions \(regions). Use sensitivity: public only if the content has nothing personal or work-related.")
            case .public:
                break
            }
        }
        if kinds.contains(.budget) {
            out.append("Today's budget for paid models is spent and no free model is left; the user can raise daily_budget_usd.")
        }
        if kinds.contains(.pause) {
            out.append("Some models are paused after errors: retry after the time shown, or pick another model from list_models.")
        }
        if kinds == [.unavailable] || (kinds.isEmpty && !pinned) {
            out.append("No provider is ready (missing keys, disabled or no models): the user sets them up in the Delegate app.")
        }
        out.append("Otherwise do the task yourself.")
        return out
    }
}
