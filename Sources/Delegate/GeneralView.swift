import DelegateCore
import SwiftUI

/// Ustawienia aplikacji i pliki. Podpięcie w Claude i diagnostyka są w Przeglądzie.
struct GeneralView: View {
    @Bindable var model: AppModel
    @State private var isEditingRawToml = false

    var body: some View {
        Form {
            Section("Aplikacja") {
                Toggle("Uruchamiaj przy logowaniu", isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle("Pokazuj dzisiejsze użycie w pasku menu", isOn: $model.showUsageInMenuBar)
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
                LabeledContent("Cennik LiteLLM") {
                    HStack {
                        Text(model.priceCatalogDate.map { "z \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "jeszcze nie pobrany")
                            .foregroundStyle(.secondary)
                        if model.refreshingPrices { ProgressView().controlSize(.small) }
                        Button("Odśwież") { Task { await model.refreshPriceCatalog() } }
                            .disabled(model.refreshingPrices)
                    }
                }
                LabeledContent("Binarka serwera") {
                    Text(model.helperURL.path(percentEncoded: false)).textSelection(.enabled).foregroundStyle(.secondary)
                }
            } header: {
                Text("Pliki")
            } footer: {
                Text("Edycja jako tekst zachowuje komentarze do następnego zapisu z formularzy, który zapisuje plik od nowa (bez komentarzy). Zmiany z zewnątrz, np. z update_models, aplikacja scala ze swoimi.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Ustawienia")
        .onAppear { model.loadPriceCatalogDate() }
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
