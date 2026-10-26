import DelegateCore
import SwiftUI

struct GeneralView: View {
    @Bindable var model: AppModel
    @State private var isEditingRawToml = false

    var body: some View {
        Form {
            Section("Claude") {
                IntegrationRow(
                    title: "Claude Desktop", state: model.desktopState, enabled: model.helperExists,
                    install: { model.installDesktop(true) }, remove: { model.installDesktop(false) })
                IntegrationRow(
                    title: "Claude Code", state: model.codeState, enabled: model.helperExists,
                    install: { Task { await model.installCode(true) } }, remove: { Task { await model.installCode(false) } })
                LabeledContent("Instrukcja dla Claude") {
                    HStack {
                        Text(model.instructionsOutdated ? "starsza wersja" : (model.instructionsInstalled ? "aktualna" : "brak"))
                            .foregroundStyle(.secondary)
                        if model.instructionsInstalled {
                            if model.instructionsOutdated { Button("Zaktualizuj") { model.installInstructions(true) } }
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
                Toggle("Pokazuj dzisiejszy koszt w pasku menu", isOn: $model.showCostInMenuBar)
            }

            Section {
                LabeledContent("Config") {
                    Button(model.home.configURL.path(percentEncoded: false)) {
                        NSWorkspace.shared.activateFileViewerSelecting([model.home.configURL])
                    }
                    .buttonStyle(.link)
                }
                LabeledContent("Edycja ręczna") {
                    Button("Edytuj delegate.toml jako tekst...") {
                        isEditingRawToml = true
                    }
                }
                LabeledContent("Binarka serwera") {
                    Text(model.helperURL.path(percentEncoded: false)).textSelection(.enabled).foregroundStyle(.secondary)
                }
            } header: {
                Text("Pliki")
            } footer: {
                Text("Edycja jako tekst zachowuje komentarze i formatowanie. Zmiany w formularzach GUI mogą nadpisywać komentarze. Jeśli macOS pyta o hasło przy użyciu kluczy przez serwer, kliknij „Zezwól serwerowi na odczyt kluczy” w sekcji Claude.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Ogólne")
        .sheet(isPresented: $isEditingRawToml) {
            RawTomlEditorSheet(model: model, isPresented: $isEditingRawToml)
        }
    }
}

private struct RawTomlEditorSheet: View {
    let model: AppModel
    @Binding var isPresented: Bool
    @State private var tomlText: String = ""
    @State private var parseError: String?
    @State private var saveSuccess = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edycja pliku delegate.toml")
                        .font(.headline)
                    Text("Wprowadź zmiany bezpośrednio w TOML. Wszystkie komentarze zostaną zachowane.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Anuluj") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Zapisz") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(parseError != nil)
                .keyboardShortcut(.defaultAction)
            }

            TextEditor(text: $tomlText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                .onChange(of: tomlText) {
                    validate()
                }

            HStack {
                if let parseError {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(parseError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Składnia TOML poprawna")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 480)
        .onAppear {
            load()
        }
    }

    private func load() {
        if let content = try? String(contentsOf: model.home.configURL, encoding: .utf8) {
            tomlText = content
        } else {
            tomlText = (try? model.config.serialized()) ?? ""
        }
        validate()
    }

    private func validate() {
        do {
            _ = try Config.parse(tomlText)
            parseError = nil
        } catch {
            parseError = "\(error.localizedDescription)"
        }
    }

    private func save() {
        guard parseError == nil else { return }
        do {
            try tomlText.write(to: model.home.configURL, atomically: true, encoding: .utf8)
            model.load()
            model.refresh()
            isPresented = false
        } catch {
            parseError = "Nie udało się zapisać: \(error.localizedDescription)"
        }
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
