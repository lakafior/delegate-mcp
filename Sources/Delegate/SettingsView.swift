import DelegateCore
import SwiftUI

enum SidebarItem: Hashable {
    case provider(String)
    case routing
    case usage
    case diagnostics
    case general
}

extension SidebarItem {
    /// `--select=routing|usage|diagnostics|general|<id dostawcy>`: do ręcznego sprawdzania widoków.
    static func fromLaunchArguments() -> SidebarItem? {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--select=") }) else { return nil }
        switch arg.dropFirst("--select=".count) {
        case "routing": return .routing
        case "usage": return .usage
        case "diagnostics": return .diagnostics
        case "general": return .general
        case let id: return .provider(String(id))
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var selection: SidebarItem? = SidebarItem.fromLaunchArguments() ?? .general
    @State private var pendingDelete: String?
    @State private var renamingProvider: String?
    @State private var renameDraft = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Dostawcy (kolejność = priorytet)") {
                    if model.config.providers.isEmpty {
                        Text("Brak dostawców. Dodaj pierwszego przyciskiem +.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.config.providers) { p in
                        Label {
                            Text(p.id)
                        } icon: {
                            StatusDot(status: model.status(of: p))
                        }
                        .tag(SidebarItem.provider(p.id))
                        .contextMenu {
                            Button("Zmień nazwę…", systemImage: "pencil") {
                                renameDraft = p.id
                                renamingProvider = p.id
                            }
                            Button("Usuń „\(p.id)”", role: .destructive) { pendingDelete = p.id }
                        }
                    }
                    .onMove { model.config.providers.move(fromOffsets: $0, toOffset: $1) }
                }
                Section("Aplikacja") {
                    Label("Routing", systemImage: "arrow.triangle.branch").tag(SidebarItem.routing)
                    Label("Użycie", systemImage: "chart.bar").tag(SidebarItem.usage)
                    Label("Diagnostyka", systemImage: "stethoscope").tag(SidebarItem.diagnostics)
                    Label("Ogólne", systemImage: "gearshape").tag(SidebarItem.general)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240)
            .toolbar {
                ToolbarItem {
                    Menu("Dodaj dostawcę", systemImage: "plus") {
                        ForEach(ProviderPreset.all) { preset in
                            Button {
                                selection = .provider(model.addProvider(from: preset))
                            } label: {
                                Label(preset.title, systemImage: preset.kind.symbol)
                            }
                        }
                    }
                }
            }
        } detail: {
            detail
        }
        .confirmationDialog(
            "Usunąć dostawcę „\(pendingDelete ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Usuń", role: .destructive) {
                if let id = pendingDelete {
                    selection = .general
                    model.removeProvider(id: id)
                }
                pendingDelete = nil
            }
        } message: {
            Text("Klucz API tego dostawcy zostanie usunięty z Keychain.")
        }
        .alert(
            "Zmień nazwę dostawcy",
            isPresented: Binding(get: { renamingProvider != nil }, set: { if !$0 { renamingProvider = nil } })
        ) {
            TextField("Nowy identyfikator", text: $renameDraft)
            Button("Anuluj", role: .cancel) { renamingProvider = nil }
            Button("Zmień") {
                if let oldId = renamingProvider {
                    let target = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if model.renameProvider(from: oldId, to: target) {
                        if selection == .provider(oldId) {
                            selection = .provider(target)
                        }
                        renamingProvider = nil
                    }
                }
            }
        } message: {
            Text("Wprowadź nowy unikalny identyfikator dostawcy.")
        }
        .onChange(of: model.config) { model.configChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reloadIfChangedOnDisk()
            model.refresh()
        }
        .safeAreaInset(edge: .bottom) { errorBar }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .provider(let id):
            if let idx = model.config.providers.firstIndex(where: { $0.id == id }) {
                ProviderDetailView(model: model, provider: $model.config.providers[idx], onRename: { newId in
                    selection = .provider(newId)
                })
                .id(id)
            } else {
                ContentUnavailableView("Brak dostawcy", systemImage: "questionmark.circle")
            }

        case .routing: RoutingView(model: model)
        case .usage: UsageView(model: model)
        case .diagnostics: DiagnosticsView(model: model)
        case .general, nil: GeneralView(model: model)
        }
    }

    @ViewBuilder
    private var errorBar: some View {
        if let err = model.saveError ?? model.loadError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(err).font(.callout).lineLimit(2)
                Spacer()
                Button("Zamknij") {
                    model.saveError = nil
                    model.loadError = nil
                }
                .controlSize(.small)
            }
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
            .padding(12)
        }
    }
}
