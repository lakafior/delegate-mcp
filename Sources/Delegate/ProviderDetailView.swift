import DelegateCore
import SwiftUI

struct ProviderDetailView: View {
    @Bindable var model: AppModel
    @Binding var provider: ProviderConfig
    @State private var keyDraft = ""
    @State private var showRemote = false
    @State private var showBulkCost = false
    @State private var bulkCost = CostSetting(category: "cheap")
    @State private var autofillMessage: String?
    @State private var autofilling = false

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
            RemoteModelsSheet(model: model, provider: provider) { infos in
                for info in infos where !provider.models.contains(where: { $0.id == info.id }) {
                    provider.models.append(Self.newModel(from: info))
                }
            }
        }
    }

    /// Nowy wpis z metadanych API: tagi z heurystyki, koszt tylko gdy API go podaje.
    private static func newModel(from info: ModelInfo) -> ModelConfig {
        var m = ModelConfig(id: info.id, tags: info.suggestedTags)
        fillCost(&m, from: info)
        return m
    }

    private static func fillCost(_ m: inout ModelConfig, from info: ModelInfo) {
        guard m.cost == nil, m.priceIn == nil, m.priceOut == nil else { return }
        if let category = info.suggestedCategory {
            m.cost = category
        } else if info.priceIn != nil || info.priceOut != nil {
            m.priceIn = info.priceIn
            m.priceOut = info.priceOut
        }
    }

    // MARK: połączenie

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

    // MARK: modele

    private var modelsSection: some View {
        Section {
            if !provider.models.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("ID modelu")
                        Text("Tagi")
                        Text("Koszt")
                        Color.clear.frame(width: 22, height: 1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ForEach($provider.models) { $m in
                        ModelRow(model: $m) { provider.models.removeAll { $0.uid == m.uid } }
                    }
                }
            }

            HStack {
                Button("Dodaj model", systemImage: "plus") { provider.models.append(ModelConfig(id: "nowy-model")) }
                if provider.kind != .foundation {
                    Button("Pobierz z API…", systemImage: "arrow.down.circle") { showRemote = true }
                }
                Spacer()
                Menu("Uzupełnij tagi", systemImage: "tag") {
                    Button("Tylko modele bez tagów") { autofill(overwrite: false) }
                    Button("Nadpisz tagi wszystkich modeli") { autofill(overwrite: true) }
                }
                .disabled(provider.models.isEmpty || autofilling)
                .fixedSize()
                Button("Koszt dla wszystkich…", systemImage: "dollarsign.circle") { showBulkCost = true }
                    .disabled(provider.models.isEmpty)
                    .popover(isPresented: $showBulkCost, arrowEdge: .bottom) { bulkCostPopover }
            }
            if let autofillMessage {
                Label(autofillMessage, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Modele")
        } footer: {
            Text("Tagi oddziel przecinkami. „Uzupełnij tagi” bierze metadane z API dostawcy (zdolności, kontekst, ceny, jeśli je podaje) i ID modelu. Claude też może to zrobić przez narzędzie update_models.")
        }
    }

    private var bulkCostPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Koszt dla wszystkich modeli „\(provider.id)”").font(.headline)
            CostEditor(setting: $bulkCost)
            HStack {
                Spacer()
                Button("Zastosuj do wszystkich (\(provider.models.count))") {
                    for i in provider.models.indices { provider.models[i].costSetting = bulkCost }
                    showBulkCost = false
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    /// Tagi (i koszt, jeśli API go podaje) z metadanych dostawcy; bez klucza tylko z ID modelu.
    private func autofill(overwrite: Bool) {
        autofilling = true
        autofillMessage = nil
        let snapshot = provider
        Task {
            var infos: [String: ModelInfo] = [:]
            var source = "z ID modeli"
            if let list = try? await model.modelInfos(for: snapshot) {
                for i in list { infos[i.id] = i }
                source = "z metadanych API"
            }
            var touched = 0
            for idx in provider.models.indices {
                let id = provider.models[idx].id
                let info = infos[id] ?? ModelInfo(id: id)
                if overwrite || provider.models[idx].tags.isEmpty {
                    let tags = info.suggestedTags
                    if !tags.isEmpty, tags != provider.models[idx].tags {
                        provider.models[idx].tags = tags
                        touched += 1
                    }
                }
                Self.fillCost(&provider.models[idx], from: info)
            }
            autofillMessage = "Uzupełniono tagi \(source): zmieniono \(touched) modeli."
            autofilling = false
        }
    }
}

private struct ModelRow: View {
    @Binding var model: ModelConfig
    let onDelete: () -> Void
    @State private var tagsText: String
    @State private var showCost = false

    init(model: Binding<ModelConfig>, onDelete: @escaping () -> Void) {
        _model = model
        self.onDelete = onDelete
        _tagsText = State(initialValue: model.wrappedValue.tags.joined(separator: ", "))
    }

    private static func parse(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        GridRow {
            TextField("ID modelu", text: $model.id)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 230)
            TextField("tagi", text: $tagsText, prompt: Text("np. code, translate"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .onChange(of: tagsText) { model.tags = Self.parse(tagsText) }
                // zmiana z zewnątrz (autouzupełnianie), bez nadpisywania wpisywanego tekstu
                .onChange(of: model.tags) {
                    if Self.parse(tagsText) != model.tags { tagsText = model.tags.joined(separator: ", ") }
                }
            Button { showCost = true } label: {
                Text(model.shortCost).frame(width: 96)
            }
            .popover(isPresented: $showCost, arrowEdge: .bottom) {
                CostEditor(setting: $model.costSetting)
                    .padding(16)
                    .frame(width: 300)
            }
            Button("Usuń model", systemImage: "trash", role: .destructive, action: onDelete)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .frame(width: 22)
        }
    }
}

private struct RemoteModelsSheet: View {
    let model: AppModel
    let provider: ProviderConfig
    let onAdd: ([ModelInfo]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var infos: [ModelInfo] = []
    @State private var chosen: Set<String> = []
    @State private var loading = true
    @State private var error: String?
    @State private var filter = ""
    @State private var showNonChat = false

    private var visible: [ModelInfo] {
        infos.filter { (showNonChat || $0.isChat) && (filter.isEmpty || $0.id.localizedCaseInsensitiveContains(filter)) }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Modele \(provider.id)").font(.headline)
            if loading {
                ProgressView().frame(maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView("Nie udało się pobrać", systemImage: "wifi.exclamationmark", description: Text(error))
            } else {
                HStack {
                    TextField("Filtruj", text: $filter).textFieldStyle(.roundedBorder)
                    Toggle("Także nie-czatowe", isOn: $showNonChat).toggleStyle(.checkbox)
                }
                List(visible, selection: $chosen) { info in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.id)
                        let tags = info.suggestedTags.joined(separator: ", ")
                        if !tags.isEmpty || !info.summary.isEmpty {
                            Text([tags, info.summary].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(info.id)
                }
            }
            HStack {
                Button("Anuluj") { dismiss() }
                Spacer()
                Button("Dodaj zaznaczone (\(chosen.count))") {
                    onAdd(infos.filter { chosen.contains($0.id) })
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .task {
            do { infos = try await model.modelInfos(for: provider) }
            catch { self.error = "\(error)" }
            loading = false
        }
    }
}
