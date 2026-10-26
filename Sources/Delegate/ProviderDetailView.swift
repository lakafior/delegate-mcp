import DelegateCore
import SwiftUI

struct ProviderDetailView: View {
    @Bindable var model: AppModel
    @Binding var provider: ProviderConfig
    var onRename: ((String) -> Void)? = nil

    @State private var keyDraft = ""
    @State private var keyEnvDraft = ""
    @FocusState private var keyEnvFocused: Bool
    @State private var showingRename = false
    @State private var renameDraft = ""
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
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(provider.id).font(.title3.bold())
                            Button {
                                renameDraft = provider.id
                                showingRename = true
                            } label: {
                                Image(systemName: "pencil")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Rename provider")
                        }
                        Text(provider.kind.title).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusDot(status: model.status(of: provider))
                    Text(model.status(of: provider).label).font(.callout)
                }
                Toggle("Enabled", isOn: $provider.enabled)
                Picker("Where data goes", selection: $provider.privacy) {
                    Text("Automatic (\(PrivacyRegion.inferred(for: provider).title))").tag(PrivacyRegion?.none)
                    ForEach(PrivacyRegion.allCases, id: \.self) { Text($0.title).tag(PrivacyRegion?.some($0)) }
                }
            }

            if provider.kind != .foundation { connection }

            Section {
                TextField("Guidance", text: Binding(
                    get: { provider.guidance ?? "" },
                    set: { provider.guidance = $0.isEmpty ? nil : $0 }),
                    prompt: Text("E.g. Good for translations. Never send work data here."), axis: .vertical)
                    .lineLimit(2...5)
            } header: {
                Text("Guidance for Claude")
            } footer: {
                Text("Claude gets this text in the server instructions next to the model list: what this provider is good for, and what not to send it. English works best. Changes take effect after restarting Claude.")
            }

            Section("Note for you") {
                TextField("E.g. plan terms, where data goes", text: Binding(
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
        .alert("Rename provider", isPresented: $showingRename) {
            TextField("New identifier", text: $renameDraft)
            Button("Cancel", role: .cancel) { showingRename = false }
            Button("Rename") {
                let target = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let oldId = provider.id
                if model.renameProvider(from: oldId, to: target) {
                    onRename?(target)
                    showingRename = false
                }
            }
        } message: {
            Text("Enter a new unique provider identifier.")
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
        Section("Connection") {
            Picker("API type", selection: $provider.kind) {
                Text(ProviderKind.openai.title).tag(ProviderKind.openai)
                Text(ProviderKind.gemini.title).tag(ProviderKind.gemini)
                Text(ProviderKind.anthropic.title).tag(ProviderKind.anthropic)
            }
            TextField("Base URL", text: $provider.baseURL)
                .textContentType(.URL)
            // Nazwa klucza to też konto w Keychain: zatwierdzamy ją w całości (Enter / wyjście z pola),
            // a AppModel przenosi zapisany klucz pod nową nazwę.
            TextField("Key name", text: $keyEnvDraft, prompt: Text("Optional (leave empty for local models, e.g. Ollama)"))
                .focused($keyEnvFocused)
                .onAppear { keyEnvDraft = provider.apiKeyEnv }
                .onChange(of: provider.apiKeyEnv) { if !keyEnvFocused { keyEnvDraft = provider.apiKeyEnv } }
                .onChange(of: keyEnvFocused) { if !keyEnvFocused { commitKeyEnv() } }
                .onSubmit { commitKeyEnv() }
                .onDisappear { commitKeyEnv() }

            HStack {
                SecureField("API key", text: $keyDraft, prompt: Text(model.keySource(for: provider) == .none ? "Paste key" : "Paste to replace"))
                Button("Save") {
                    model.setKey(keyDraft, for: provider)
                    keyDraft = ""
                }
                .buttonStyle(.glassProminent)
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            LabeledContent("Key") {
                HStack {
                    Text(model.keySource(for: provider).label).foregroundStyle(.secondary)
                    if model.keySource(for: provider) == .keychain {
                        Button("Remove from Keychain", role: .destructive) { model.removeKey(for: provider) }
                    }
                }
            }
            if model.keySource(for: provider) == .none,
               let url = ProviderPreset.all.first(where: { $0.baseURL == provider.baseURL })?.keyURL.flatMap(URL.init(string:)) {
                Link("Where to get an API key", destination: url)
            }

            Stepper(value: Binding(
                get: { provider.timeoutSeconds ?? 0 },
                set: { provider.timeoutSeconds = $0 > 0 ? $0 : nil }
            ), in: 0...600, step: 10) {
                LabeledContent("Custom timeout", value: provider.timeoutSeconds.map { "\(Int($0)) s" } ?? "default from routing")
            }

            testRow
        }
    }

    private func commitKeyEnv() {
        model.setKeyEnv(keyEnvDraft, forProvider: provider.id)
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
                Button("Test connection") { model.test(provider) }
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
                        Text("Model ID")
                        Text("Tags")
                        Text("Cost")
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
                Button("Add model", systemImage: "plus") { provider.models.append(ModelConfig(id: "new-model")) }
                if provider.kind != .foundation {
                    Button("Fetch from API…", systemImage: "arrow.down.circle") { showRemote = true }
                }
                Spacer()
                Menu("Fill from API", systemImage: "wand.and.stars") {
                    Section("Tags") {
                        Button("Only models without tags") { autofill(overwrite: false) }
                        Button("Overwrite tags of all models") { autofill(overwrite: true) }
                    }
                    Section("Prices") {
                        Button("Fetch prices for all models") { fetchPrices() }
                        Button("Refresh LiteLLM price list and fetch prices") { fetchPrices(refreshCatalog: true) }
                    }
                }
                .disabled(provider.models.isEmpty || autofilling)
                .fixedSize()
                Button("Cost for all…", systemImage: "dollarsign.circle") { showBulkCost = true }
                    .disabled(provider.models.isEmpty)
                    .popover(isPresented: $showBulkCost, arrowEdge: .bottom) { bulkCostPopover }
            }
            if let autofillMessage {
                Label(autofillMessage, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Models")
        } footer: {
            Text("Separate tags with commas. \"Fill from API\" takes the provider's metadata (capabilities, context, prices if provided) and model IDs. Prices come from the API (OpenRouter, Venice and compatible ones), and when the API doesn't provide them, from the public LiteLLM price list (Mistral, Gemini, DeepSeek, Anthropic, OpenAI and others). Claude can also do this via the update_models tool.")
        }
    }

    private var bulkCostPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cost for all models of \"\(provider.id)\"").font(.headline)
            CostEditor(setting: $bulkCost)
            HStack {
                Spacer()
                Button("Apply to all (\(provider.models.count))") {
                    for i in provider.models.indices { provider.models[i].costSetting = bulkCost }
                    showBulkCost = false
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    /// Ceny z API dla istniejących modeli: nadpisuje kategorię kwotami (albo „darmowy”, gdy API podaje 0).
    /// Modeli oznaczonych jako darmowe nie ruszamy, jeśli API podaje cenę: to zwykle świadomy wybór
    /// (darmowy plan, np. Mistral Experiment), a cena katalogowa by go zepsuła.
    private func fetchPrices(refreshCatalog: Bool = false) {
        autofilling = true
        autofillMessage = nil
        let snapshot = provider
        Task {
            defer { autofilling = false }
            if refreshCatalog, !(await model.refreshPriceCatalog()) {
                autofillMessage = "Couldn't fetch the LiteLLM price list (no network?). Using the last copy."
            }
            guard let list = try? await model.modelInfos(for: snapshot) else {
                autofillMessage = "Couldn't fetch the model list from the API (check the key and the connection test)."
                return
            }
            let infos = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var updated = 0, keptFree = 0, noPrice = 0
            for idx in provider.models.indices {
                guard let info = infos[provider.models[idx].id], info.priceIn != nil || info.priceOut != nil else {
                    noPrice += 1
                    continue
                }
                var m = provider.models[idx]
                if info.suggestedCategory == "free" {
                    m.costSetting = CostSetting(category: "free")
                } else if m.cost == "free" {
                    keptFree += 1
                    continue
                } else {
                    m.costSetting = CostSetting(priceIn: info.priceIn, priceOut: info.priceOut)
                }
                if m != provider.models[idx] {
                    provider.models[idx] = m
                    updated += 1
                }
            }
            var parts = ["Prices updated: \(updated)."]
            if noPrice > 0 { parts.append("No price in API: \(noPrice).") }
            if keptFree > 0 { parts.append("Skipped \(keptFree) marked as free; change manually if you pay for them.") }
            if list.allSatisfy({ $0.priceIn == nil && $0.priceOut == nil }) {
                parts = ["Neither this provider's API nor the LiteLLM price list gives prices for it. Set them manually with the cost button next to the model."]
            }
            model.loadPriceCatalogDate()
            if let date = model.priceCatalogDate {
                parts.append("LiteLLM price list from \(date.formatted(date: .abbreviated, time: .shortened)).")
            }
            autofillMessage = [autofillMessage, parts.joined(separator: " ")].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// Tagi (i koszt, jeśli API go podaje) z metadanych dostawcy; bez klucza tylko z ID modelu.
    private func autofill(overwrite: Bool) {
        autofilling = true
        autofillMessage = nil
        let snapshot = provider
        Task {
            var infos: [String: ModelInfo] = [:]
            var source = "from model IDs"
            if let list = try? await model.modelInfos(for: snapshot) {
                for i in list { infos[i.id] = i }
                source = "from API metadata"
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
            autofillMessage = "Tags filled \(source): changed \(touched) models."
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
            TextField("Model ID", text: $model.id)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 150, idealWidth: 220, maxWidth: 280)
            TextField("tags", text: $tagsText, prompt: Text("e.g. code, translate"))
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
            Button("Delete model", systemImage: "trash", role: .destructive, action: onDelete)
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
            Text("Models of \(provider.id)").font(.headline)
            if loading {
                ProgressView().frame(maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView("Couldn't fetch", systemImage: "wifi.exclamationmark", description: Text(error))
            } else {
                HStack {
                    TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
                    Toggle("Include non-chat", isOn: $showNonChat).toggleStyle(.checkbox)
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
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add selected (\(chosen.count))") {
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
