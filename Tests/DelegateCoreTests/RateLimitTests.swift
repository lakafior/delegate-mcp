import Foundation
import Testing
@testable import DelegateCore

@Suite struct RateLimitTests {
    @Test func durationsInTheFormatsProvidersUse() {
        #expect(RateLimit.duration("2m59.56s") == 179.56)
        #expect(RateLimit.duration("7.66s") == 7.66)
        #expect(RateLimit.duration("120ms") == 0.12)   // nie 120 minut
        #expect(RateLimit.duration("1h2m3s") == 3723)
        #expect(RateLimit.duration("60") == 60)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(RateLimit.duration("2000000090", now: now) == 90)   // czas uniksowy = moment odnowienia
        #expect(RateLimit.duration("soon") == nil)
        #expect(RateLimit.duration("5x") == nil)
    }

    @Test func headersAreReadCaseInsensitively() {
        let limits = RateLimit.parse([
            "X-RateLimit-Remaining-Requests": "998", "x-ratelimit-reset-requests": "2m59.56s",
            "x-ratelimit-remaining-tokens": "1200", "X-Ratelimit-Reset-Tokens": "7.66s",
            "x-ratelimit-limit-tokens": "8000", "content-type": "application/json",
        ])
        #expect(limits == [RateLimit(name: "requests", remaining: 998, reset: 179.56),
                           RateLimit(name: "tokens", remaining: 1200, reset: 7.66)])
    }

    @Test func pauseWhenALimitIsUsedUpOrTooLowForAnotherSimilarRequest() {
        #expect(RateLimit.pause([RateLimit(name: "tokens", remaining: 5000, reset: 7)], usedTokens: 3000) == nil)
        let low = RateLimit.pause([RateLimit(name: "tokens", remaining: 2000, reset: 7.5)], usedTokens: 3000)
        #expect(low?.seconds == 7.5 && low?.reason.contains("2000 tokens left") == true)
        // Wyczerpany licznik zapytań dziennych waży więcej niż chwilowy brak tokenów.
        let both = RateLimit.pause([RateLimit(name: "requests", remaining: 0, reset: 180),
                                    RateLimit(name: "tokens", remaining: 100, reset: 5)], usedTokens: 3000)
        #expect(both?.seconds == 180 && both?.reason.contains("remaining-requests: 0") == true)
        // Bez czasu odnowienia: dzienny licznik godzina, reszta minuta; nigdy dłużej niż doba.
        #expect(RateLimit.pause([RateLimit(name: "requests-day", remaining: 0)], usedTokens: nil)?.seconds == 3600)
        #expect(RateLimit.pause([RateLimit(name: "requests", remaining: 0)], usedTokens: nil)?.seconds == 60)
        #expect(RateLimit.pause([RateLimit(name: "tokens", remaining: 0, reset: 9_999_999)], usedTokens: nil)?.seconds == 86_400.0)
    }

    @Test func modelNearItsLimitIsSkippedBeforeItRefuses() async throws {
        let t = MockTransport([
            "api.mistral.ai": .init(status: 200, body: openAIBody, headers: [
                "x-ratelimit-remaining-tokens": "5", "x-ratelimit-reset-tokens": "30s",
            ]),
            "generativelanguage.googleapis.com": .init(status: 200, body: geminiBody),
        ])
        let (svc, _) = try makeService(t, keys: ["MISTRAL_API_KEY": "m", "GEMINI_API_KEY": "g"])
        let first = try await svc.delegate(.init(prompt: "x", model: "mistral/mistral-small-latest"))
        #expect(first.contains("mistral/mistral-small-latest"))   // ta odpowiedź przeszła…
        let pause = try #require(svc.cooldowns.active()["mistral/mistral-small-latest"])
        #expect(pause.reason.contains("5 tokens left, the last request took 13"))
        #expect(pause.until.timeIntervalSinceNow > 20 && pause.until.timeIntervalSinceNow <= 30)
        // …a następne idzie od razu gdzie indziej, bez nieudanej próby.
        let second = try await svc.delegate(.init(prompt: "x", model: "mistral/mistral-small-latest"))
        #expect(second.contains("gemini/") && second.contains("skipped (paused): mistral/mistral-small-latest"))
        #expect(t.calls.filter { $0.url?.host == "api.mistral.ai" }.count == 1)
    }

    @Test func retryAfterHeaderSetsThePauseOn429() async throws {
        let t = MockTransport([
            "api.mistral.ai": .init(status: 429, body: #"{"error":"rate limit"}"#, headers: ["retry-after": "42"]),
            "generativelanguage.googleapis.com": .init(status: 200, body: geminiBody),
        ])
        let (svc, _) = try makeService(t, keys: ["MISTRAL_API_KEY": "m", "GEMINI_API_KEY": "g"])
        _ = try await svc.delegate(.init(prompt: "x", model: "mistral/mistral-small-latest"))
        let pause = try #require(svc.cooldowns.active()["mistral/mistral-small-latest"])
        #expect(pause.reason == "quota exhausted (HTTP 429)")
        #expect(pause.until.timeIntervalSinceNow > 25 && pause.until.timeIntervalSinceNow <= 42)
    }

    @Test func freeProviderPresetsHaveRegionsAndKeys() throws {
        for id in ["groq", "nvidia", "sambanova", "cloudflare"] {
            let p = try #require(ProviderPreset.all.first { $0.id == id })
            #expect(p.privacy == .us && p.keyURL != nil && !p.models.isEmpty)
            #expect(p.models.allSatisfy { $0.cost == "free" })
            #expect(PrivacyRegion.inferred(for: ProviderConfig(id: id, kind: .openai, baseURL: p.baseURL)) == .us)
        }
    }
}
