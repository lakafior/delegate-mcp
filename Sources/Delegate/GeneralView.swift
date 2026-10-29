import DelegateCore
import SwiftUI

/// Ustawienia aplikacji i pliki. Podpięcie w Claude i diagnostyka są w Przeglądzie.
struct GeneralView: View {
    @Bindable var model: AppModel
    @State private var isEditingRawToml = false

    var body: some View {
        Form {
            Section("App") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle("Show today's usage in the menu bar", isOn: $model.showUsageInMenuBar)
            }

            Section {
                Toggle("Check for updates daily", isOn: $model.checkForUpdates)
                LabeledContent("Version") {
                    HStack {
                        Text(updateStatus).foregroundStyle(.secondary)
                        if model.checkingForUpdates { ProgressView().controlSize(.small) }
                        Button("Check Now") { Task { await model.checkForUpdatesNow() } }
                            .disabled(model.checkingForUpdates || model.appVersion == nil)
                    }
                }
                if let update = model.availableUpdate {
                    LabeledContent("Version \(update.version) is available") {
                        HStack {
                            Button("Release Notes") { NSWorkspace.shared.open(update.pageURL) }
                            Button("Download") { NSWorkspace.shared.open(update.dmgURL ?? update.pageURL) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    if !update.notes.isEmpty {
                        Text(LocalizedStringKey(Self.inlineMarkdown(update.notes)))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Asks GitHub Releases for the latest version; nothing else is sent. To update, open the DMG and replace Delegate in Applications.")
            }

            Section {
                LabeledContent("Config") {
                    Button(model.home.configURL.path(percentEncoded: false)) {
                        NSWorkspace.shared.activateFileViewerSelecting([model.home.configURL])
                    }
                    .buttonStyle(.link)
                }
                LabeledContent("Manual editing") {
                    Button("Edit delegate.toml as text...") {
                        isEditingRawToml = true
                    }
                }
                LabeledContent("LiteLLM price list") {
                    HStack {
                        Text(model.priceCatalogDate.map { "from \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "not downloaded yet")
                            .foregroundStyle(.secondary)
                        if model.refreshingPrices { ProgressView().controlSize(.small) }
                        Button("Refresh") { Task { await model.refreshPriceCatalog() } }
                            .disabled(model.refreshingPrices)
                    }
                }
                LabeledContent("Server binary") {
                    Text(model.helperURL.path(percentEncoded: false)).textSelection(.enabled).foregroundStyle(.secondary)
                }
            } header: {
                Text("Files")
            } footer: {
                Text("Editing as text keeps comments until the next save from the forms, which rewrites the file without comments. Outside changes, e.g. from update_models, are merged with the app's own.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { model.loadPriceCatalogDate() }
        .sheet(isPresented: $isEditingRawToml) {
            RawTomlEditorSheet(model: model, isPresented: $isEditingRawToml)
        }
    }

    /// `Text` rozumie tylko Markdown w linii: nagłówki z notatek GitHuba pogrubiamy, listy zamieniamy na kropki.
    private static func inlineMarkdown(_ notes: String) -> String {
        notes.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                return "**\(trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))**"
            }
            if trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") { return "• " + trimmed.dropFirst(2) }
            return String(line)
        }.joined(separator: "\n")
    }

    private var updateStatus: String {
        guard let version = model.appVersion else { return "development build" }
        if model.availableUpdate != nil { return "\(version), update available" }
        if model.updateCheckError != nil { return "\(version), couldn't check" }
        guard let last = model.lastUpdateCheck else { return version }
        return "\(version), up to date (checked \(last.formatted(.relative(presentation: .named))))"
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
                    Text("Edit delegate.toml")
                        .font(.headline)
                    Text("Make changes directly in the TOML. All comments will be kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
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
                    Text("TOML syntax is valid")
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
            parseError = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
