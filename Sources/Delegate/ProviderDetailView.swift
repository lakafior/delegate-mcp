import DelegateCore
import SwiftUI

struct ProviderDetailView: View {
    @Bindable var model: AppModel
    @Binding var provider: ProviderConfig
    @State private var keyDraft = ""
    @State private var showRemote = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: provider.kind.symbol).font(.title2)
                    VStack(alignment: .leading) {
                        Text(provider.id).font(.title3.bold())
                        Text(provider.kind.title).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusDot(status: model.status(of: provider))
                    Text(model.status(of: provider).label).font(.callout)
                }
                Toggle("Włączony", isOn: $provider.enabled)
            }

            if provider.kind != .foundation { connection }

            Section("Uwaga dla Ciebie") {
                TextField("Np. gdzie trafiają dane", text: Binding(
                    get: { provider.note ?? "" },
                    set: { provider.note = $0.isEmpty ? nil : $0 }), axis: .vertical)
            }

            modelsSection
        }
        .formStyle(.grouped)
        .navigationTitle(provider.id)
        .sheet(isPresented: $showRemote) {
            RemoteModelsSheet(model: model, provider: provider) { ids in
                for id in ids where !provider.models.contains(where: { $0.id == id }) {
                    provider.models.append(ModelConfig(id: id))
                }
            }
        }
    }

    private var connection: some View {
        Section("Połączenie") {
            Picker("Typ API", selection: $provider.kind) {
                Text(ProviderKind.openai.title).tag(ProviderKind.openai)
                Text(ProviderKind.gemini.title).tag(ProviderKind.gemini)
            }
            TextField("Adres bazowy", text: $provider.baseURL)
                .textContentType(.URL)
            TextField("Nazwa klucza", text: $provider.apiKeyEnv)

            HStack {
                SecureField("Klucz API", text: $keyDraft, prompt: Text(model.keySource(for: provider) == .none ? "Wklej klucz" : "Wklej, żeby zastąpić"))
                Button("Zapisz") {
                    model.setKey(keyDraft, for: provider)
                    keyDraft = ""
                }
                .buttonStyle(.glassProminent)
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            LabeledContent("Klucz") {
                HStack {
                    Text(model.keySource(for: provider).label).foregroundStyle(.secondary)
                    if model.keySource(for: provider) == .keychain {
                        Button("Usuń z Keychain", role: .destructive) { model.removeKey(for: provider) }
                    }
                }
            }
            testRow
        }
    }

    private var testRow: some View {
        LabeledContent("Test") {
            HStack {
                if let result = model.testResults[provider.id] {
                    switch result {
                    case .success(let m): Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failure(let e): Label(e.description, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2)
                    }
                }
                if model.testing.contains(provider.id) { ProgressView().controlSize(.small) }
                Button("Testuj połączenie") { model.test(provider) }
                    .disabled(model.testing.contains(provider.id))
            }
        }
    }

    private var modelsSection: some View {
        Section {
            ForEach($provider.models) { $m in
                ModelRow(model: $m) { provider.models.removeAll { $0.uid == m.uid } }
            }
            HStack {
                Button("Dodaj model", systemImage: "plus") { provider.models.append(ModelConfig(id: "nowy-model")) }
                if provider.kind != .foundation {
                    Button("Pobierz z API…", systemImage: "arrow.down.circle") { showRemote = true }
                }
            }
        } header: {
            Text("Modele")
        } footer: {
            Text("Tagi oddziel przecinkami (np. code, translate). Claude wybiera model po tagu zadania.")
        }
    }
}

private struct ModelRow: View {
    @Binding var model: ModelConfig
    let onDelete: () -> Void
    @State private var tagsText: String

    init(model: Binding<ModelConfig>, onDelete: @escaping () -> Void) {
        _model = model
        self.onDelete = onDelete
        _tagsText = State(initialValue: model.wrappedValue.tags.joined(separator: ", "))
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("ID modelu", text: $model.id)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160)
            TextField("tagi", text: $tagsText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: tagsText) {
                    model.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
            TextField("koszt", text: Binding(
                get: { model.cost ?? "" },
                set: { model.cost = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
            Button("Usuń model", systemImage: "trash", role: .destructive, action: onDelete)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }
}

private struct RemoteModelsSheet: View {
    let model: AppModel
    let provider: ProviderConfig
    let onAdd: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ids: [String] = []
    @State private var chosen: Set<String> = []
    @State private var loading = true
    @State private var error: String?
    @State private var filter = ""

    private var visible: [String] {
        filter.isEmpty ? ids : ids.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Modele \(provider.id)").font(.headline)
            if loading {
                ProgressView().frame(maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView("Nie udało się pobrać", systemImage: "wifi.exclamationmark", description: Text(error))
            } else {
                TextField("Filtruj", text: $filter).textFieldStyle(.roundedBorder)
                List(visible, id: \.self, selection: $chosen) { id in Text(id) }
            }
            HStack {
                Button("Anuluj") { dismiss() }
                Spacer()
                Button("Dodaj zaznaczone (\(chosen.count))") {
                    onAdd(ids.filter { chosen.contains($0) })
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440, height: 480)
        .task {
            do { ids = try await model.remoteModels(for: provider) }
            catch { self.error = "\(error)" }
            loading = false
        }
    }
}
