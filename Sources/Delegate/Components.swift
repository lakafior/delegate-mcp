import DelegateCore
import SwiftUI

extension ProviderStatus {
    var color: Color {
        switch self {
        case .ready: .green
        case .disabled: .secondary
        case .missingKey: .orange
        case .unavailable: .red
        }
    }
}

struct StatusDot: View {
    let status: ProviderStatus

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 9, height: 9)
            .accessibilityLabel(status.label)
    }
}

extension PrivacyRegion {
    var title: String {
        switch self {
        case .local: "local (this Mac)"
        case .eu: "EU"
        case .us: "US"
        case .cn: "China"
        case .other: "unknown"
        }
    }
}

extension Sensitivity {
    var title: String {
        switch self {
        case .public: "public"
        case .personal: "personal / work"
        case .private: "private (Mac only)"
        }
    }
}

extension DelegationMode {
    var title: String {
        switch self {
        case .conservative: "Cautious"
        case .balanced: "Balanced"
        case .aggressive: "Aggressive"
        }
    }

    var explanation: String {
        switch self {
        case .conservative: "The assistant delegates only clearly long text tasks (threshold around 400 words)."
        case .balanced: "The assistant delegates actively when a task fits (threshold around 150 words)."
        case .aggressive: "The assistant delegates by default, even short drafts and rewrites (threshold around 50 words)."
        }
    }
}

extension ProviderKind {
    var title: String {
        switch self {
        case .openai: "OpenAI-compatible API"
        case .gemini: "Gemini"
        case .anthropic: "Anthropic"
        case .foundation: "On-device (Apple)"
        }
    }

    var symbol: String {
        switch self {
        case .openai: "network"
        case .gemini: "sparkles"
        case .anthropic: "cpu"
        case .foundation: "apple.intelligence"
        }
    }
}
