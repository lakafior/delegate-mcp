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
                    "x.ai", "groq.com", "together.xyz", "perplexity.ai"]) { return .us }
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
    public var ref: String
    public var reason: String

    static let pausePrefix = "paused until"
    /// Model pominięty, bo ma przerwę po błędzie (`ModelCooldowns`).
    public var isPause: Bool { reason.hasPrefix(Self.pausePrefix) }
}

/// Co serwer zrobiłby z zadaniem: kolejność prób i co pominął.
public struct RoutingPlan: Sendable {
    public var candidates: [Candidate]
    public var excluded: [RoutingExclusion]
    /// Wydane dziś na płatne modele (z logu), gdy ustawiono budżet.
    public var spentToday: Double?
}
