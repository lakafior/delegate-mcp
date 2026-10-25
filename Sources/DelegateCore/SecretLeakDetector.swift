import Foundation

public struct DetectedSecret: Sendable, Equatable {
    public let type: String
    public let matched: String

    public init(type: String, matched: String) {
        self.type = type
        self.matched = matched
    }
}

/// Heurystyczny detektor sekretów w promptach, zapobiegający przypadkowemu wyciekowi danych.
public enum SecretLeakDetector: Sendable {
    private static let patterns: [(type: String, pattern: String)] = [
        ("OpenAI API Key", #"\b(sk-[a-zA-Z0-9_-]{20,})\b"#),
        ("Anthropic API Key", #"\b(sk-ant-[a-zA-Z0-9_-]{20,})\b"#),
        ("GitHub Token", #"\b(gh[pousr]_[a-zA-Z0-9]{36,}|github_pat_[a-zA-Z0-9_]{40,})\b"#),
        ("Google API Key", #"\b(AIza[0-9A-Za-z-_]{30,40})\b"#),
        ("AWS Access Key", #"\b(AKIA[0-9A-Z]{16})\b"#),
        ("Private Key", #"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"#),
        ("Bearer Token", #"\bBearer\s+([a-zA-Z0-9_\-\.]{30,})\b"#),
    ]

    public static func scan(_ text: String) -> DetectedSecret? {
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p.pattern, options: []) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let matchRange = Range(match.range, in: text) {
                let val = String(text[matchRange])
                let masked: String
                if val.count > 10 {
                    masked = val.prefix(4) + "..." + val.suffix(4)
                } else {
                    masked = "***"
                }
                return DetectedSecret(type: p.type, matched: masked)
            }
        }
        return nil
    }
}
