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

extension ProviderKind {
    var title: String {
        switch self {
        case .openai: "API zgodne z OpenAI"
        case .gemini: "Gemini"
        case .foundation: "Na urządzeniu (Apple)"
        }
    }

    var symbol: String {
        switch self {
        case .openai: "network"
        case .gemini: "sparkles"
        case .foundation: "apple.intelligence"
        }
    }
}
