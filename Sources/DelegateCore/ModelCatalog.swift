import Foundation

public enum CostCategory {
    public static let all = ["free", "cheap", "paid", "varies"]
}

/// Metadane modelu z API dostawcy (to, co dostawca zdradza) plus podpowiedzi tagów.
public struct ModelInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var contextLength: Int?
    /// USD za 1M tokenów.
    public var priceIn: Double?
    public var priceOut: Double?
    public var vision = false
    public var reasoning = false
    public var tools = false
    /// `false` dla embeddingów, moderacji, OCR, audio itp.
    public var isChat = true
    /// Skąd są ceny, gdy nie z API dostawcy (np. „LiteLLM”).
    public var priceSource: String?

    public init(id: String, contextLength: Int? = nil, priceIn: Double? = nil, priceOut: Double? = nil,
                vision: Bool = false, reasoning: Bool = false, tools: Bool = false, isChat: Bool? = nil) {
        self.id = id
        self.contextLength = contextLength
        self.priceIn = priceIn
        self.priceOut = priceOut
        self.vision = vision
        self.reasoning = reasoning
        self.tools = tools
        self.isChat = isChat ?? TagSuggester.looksLikeChat(id)
    }

    public var suggestedTags: [String] { TagSuggester.tags(for: self) }

    /// `free`, gdy API podaje zerowe ceny; w innym razie `nil` (nie zgadujemy).
    public var suggestedCategory: String? {
        guard let i = priceIn, let o = priceOut else { return nil }
        return i == 0 && o == 0 ? "free" : nil
    }

    /// Krótki opis do `list_remote_models` i GUI.
    public var summary: String {
        var parts: [String] = []
        if let c = contextLength { parts.append("kontekst \(c >= 1000 ? "\(c / 1000)k" : "\(c)")") }
        if priceIn != nil || priceOut != nil {
            var price = "$\(ModelConfig.money(priceIn))/$\(ModelConfig.money(priceOut)) za 1M"
            if let priceSource { price += " wg \(priceSource)" }
            parts.append(price)
        }
        if !isChat { parts.append("nie czat") }
        return parts.joined(separator: " · ")
    }
}

/// Heurystyka tagów z ID modelu i metadanych. Celowo prosta i przewidywalna.
public enum TagSuggester {
    private static func tokens(_ id: String) -> [String] {
        id.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func has(_ tokens: [String], anyPrefix prefixes: [String]) -> Bool {
        tokens.contains { t in prefixes.contains { t.hasPrefix($0) } }
    }

    public static func looksLikeChat(_ id: String) -> Bool {
        let t = tokens(id)
        let nonChat = ["embed", "embedding", "moderation", "ocr", "tts", "whisper", "transcribe", "voxtral",
                       "imagen", "veo", "dall", "rerank", "guard", "speech", "audio", "image"]
        return !t.contains { tok in nonChat.contains { tok.hasPrefix($0) } }
    }

    /// Model na urządzeniu: małe okno kontekstu, więc nie jako ogólny, tylko do prywatnych i krótkich zadań.
    public static let onDeviceTags = ["private", "short", "offline"]

    public static func tags(for info: ModelInfo) -> [String] {
        guard info.isChat else { return [] }
        if info.id == "on-device" { return onDeviceTags }
        let t = tokens(info.id)
        let isCode = has(t, anyPrefix: ["code", "coder", "codestral", "devstral"])
        // Model „rozumujący” z nazwy jest wyspecjalizowany; flaga z API („umie myśleć”) dotyczy dziś
        // większości modeli ogólnych, więc dodaje tag `reasoning`, ale nie odbiera ogólnych.
        let reasoningByName = has(t, anyPrefix: ["reason", "thinking", "magistral"])
            || t.contains { ["r1", "o1", "o3", "o4", "pro"].contains($0) }
        let isReasoning = reasoningByName || info.reasoning
        let isFast = has(t, anyPrefix: ["flash", "mini", "small", "lite", "nano", "haiku", "instant", "turbo", "tiny", "fast"])

        var tags: [String] = []
        if isCode { tags.append("code") }
        if !isCode && !reasoningByName { tags += ["general", "translate", "summarize"] }
        if isReasoning { tags.append("reasoning") }
        if isFast { tags.append("fast") }
        if info.vision || has(t, anyPrefix: ["vision", "pixtral"]) || t.contains("vl") { tags.append("vision") }
        if let c = info.contextLength, c >= 200_000 { tags.append("long-context") }
        var seen = Set<String>()
        return tags.filter { seen.insert($0).inserted }
    }
}
