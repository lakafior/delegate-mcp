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
        case .local: "lokalnie (ten Mac)"
        case .eu: "UE"
        case .us: "USA"
        case .cn: "Chiny"
        case .other: "nieznany"
        }
    }
}

extension Sensitivity {
    var title: String {
        switch self {
        case .public: "publiczne"
        case .personal: "osobiste / praca"
        case .private: "prywatne (tylko Mac)"
        }
    }
}

extension DelegationMode {
    var title: String {
        switch self {
        case .conservative: "Ostrożnie"
        case .balanced: "Zrównoważenie"
        case .aggressive: "Agresywnie"
        }
    }

    var explanation: String {
        switch self {
        case .conservative: "Claude deleguje tylko wyraźnie długie zadania tekstowe (próg ok. 400 słów)."
        case .balanced: "Claude deleguje aktywnie, gdy zadanie pasuje (próg ok. 150 słów)."
        case .aggressive: "Claude deleguje domyślnie, nawet krótkie drafty i przeróbki (próg ok. 50 słów)."
        }
    }
}

extension ProviderKind {
    var title: String {
        switch self {
        case .openai: "API zgodne z OpenAI"
        case .gemini: "Gemini"
        case .anthropic: "Anthropic"
        case .foundation: "Na urządzeniu (Apple)"
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
