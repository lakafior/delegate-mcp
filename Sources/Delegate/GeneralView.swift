import DelegateCore
import SwiftUI

struct GeneralView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Claude") {
                IntegrationRow(
                    title: "Claude Desktop", state: model.desktopState, enabled: model.helperExists,
                    install: { model.installDesktop(true) }, remove: { model.installDesktop(false) })
                IntegrationRow(
                    title: "Claude Code", state: model.codeState, enabled: model.helperExists,
                    install: { model.installCode(true) }, remove: { model.installCode(false) })
                LabeledContent("Instrukcja delegowania") {
                    HStack {
                        Text(model.instructionsInstalled ? "dopisana" : "brak").foregroundStyle(.secondary)
                        if model.instructionsInstalled {
                            Button("Usuń") { model.installInstructions(false) }
                        } else {
                            Button("Dopisz do ~/.claude/CLAUDE.md") { model.installInstructions(true) }
                        }
                    }
                }
                LabeledContent("Dostęp do Keychain") {
                    Button("Zezwól serwerowi na odczyt kluczy") { model.reauthorizeKeys() }
                        .disabled(!model.helperExists)
                }
                if let message = model.integrationMessage {
                    Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                if !model.helperExists {
                    Label("Nie znaleziono delegate-mcp obok aplikacji. Zbuduj całość skryptem scripts/build-app.sh.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                }
            }

            Section("Model na urządzeniu") {
                LabeledContent("Apple Intelligence") {
                    switch model.onDevice {
                    case .available: Label("dostępny", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .unavailable(let why): Text(why).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Aplikacja") {
                Toggle("Uruchamiaj przy logowaniu", isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }

            Section {
                LabeledContent("Config") {
                    Button(model.home.configURL.path(percentEncoded: false)) {
                        NSWorkspace.shared.activateFileViewerSelecting([model.home.configURL])
                    }
                    .buttonStyle(.link)
                }
                LabeledContent("Binarka serwera") {
                    Text(model.helperURL.path(percentEncoded: false)).textSelection(.enabled).foregroundStyle(.secondary)
                }
            } header: {
                Text("Pliki")
            } footer: {
                Text("Zapis z aplikacji przepisuje delegate.toml i nie zachowuje komentarzy. Jeśli macOS pyta o hasło przy użyciu kluczy przez serwer, kliknij „Zezwól serwerowi na odczyt kluczy” w sekcji Claude.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Ogólne")
    }
}

private struct IntegrationRow: View {
    let title: String
    let state: IntegrationState
    let enabled: Bool
    let install: () -> Void
    let remove: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(state.label).foregroundStyle(state == .installed ? .green : .secondary)
                switch state {
                case .installed:
                    Button("Usuń", action: remove)
                case .notInstalled:
                    Button("Zainstaluj", action: install).disabled(!enabled)
                case .stale:
                    Button("Napraw", action: install).disabled(!enabled)
                }
            }
        }
    }
}
