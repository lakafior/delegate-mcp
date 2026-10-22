import Foundation
import FoundationModels

public enum OnDeviceAvailability: Sendable, Equatable {
    case available
    case unavailable(String)

    public var isAvailable: Bool { self == .available }
}

/// Model działający lokalnie. Wydzielony, żeby dało się go podmienić w testach.
public protocol OnDeviceModel: Sendable {
    var availability: OnDeviceAvailability { get }
    func respond(_ request: ChatRequest) async throws -> ChatReply
}

/// Apple Foundation Models (`SystemLanguageModel`). Zużycia tokenów system nie zwraca.
public struct FoundationOnDeviceModel: OnDeviceModel {
    public init() {}

    public var availability: OnDeviceAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable("urządzenie nie obsługuje Apple Intelligence")
            case .appleIntelligenceNotEnabled: return .unavailable("Apple Intelligence jest wyłączone")
            case .modelNotReady: return .unavailable("model jeszcze się pobiera")
            @unknown default: return .unavailable("niedostępny")
            }
        }
    }

    public func respond(_ request: ChatRequest) async throws -> ChatReply {
        guard availability.isAvailable else {
            if case .unavailable(let why) = availability { throw ProviderError.badResponse(why) }
            throw ProviderError.badResponse("model na urządzeniu niedostępny")
        }
        let session: LanguageModelSession
        if let system = request.system, !system.isEmpty {
            session = LanguageModelSession(instructions: system)
        } else {
            session = LanguageModelSession()
        }
        var options = GenerationOptions()
        if let t = request.temperature { options.temperature = t }
        if let m = request.maxTokens { options.maximumResponseTokens = m }
        do {
            let response = try await session.respond(to: request.prompt, options: options)
            return ChatReply(text: response.content, inputTokens: nil, outputTokens: nil)
        } catch {
            throw ProviderError.badResponse(error.localizedDescription)
        }
    }
}
