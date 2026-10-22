import DelegateCore
import SwiftUI

enum SidebarItem: Hashable {
    case provider(String)
    case routing
    case usage
    case general
}

extension SidebarItem {
    /// `--select=routing|usage|general|<id dostawcy>`: do ręcznego sprawdzania widoków.
    static func fromLaunchArguments() -> SidebarItem? {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--select=") }) else { return nil }
        switch arg.dropFirst("--select=".count) {
        case "routing": return .routing
        case "usage": return .usage
        case "general": return .general
        case let id: return .provider(String(id))
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var selection: SidebarItem? = SidebarItem.fromLaunchArguments() ?? .general
    @State private var pendingDelete: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Dostawcy (kolejność = priorytet)") {
                    ForEach(model.config.providers) { p in
                        Label {
                            Text(p.id)
                        } icon: {
                            StatusDot(status: model.status(of: p))
                        }
                        .tag(SidebarItem.provider(p.id))
                        .contextMenu {
                            Button("Usuń „\(p.id)”", role: .destructive) { pendingDelete = p.id }
                        }
                    }
                    .onMove { model.config.providers.move(fromOffsets: $0, toOffset: $1) }
                }
                Section("Aplikacja") {
                    Label("Routing", systemImage: "arrow.triangle.branch").tag(SidebarItem.routing)
                    Label("Użycie", systemImage: "chart.bar").tag(SidebarItem.usage)
                    Label("Ogólne", systemImage: "gearshape").tag(SidebarItem.general)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240)
            .toolbar {
                ToolbarItem {
                    Button("Dodaj dostawcę", systemImage: "plus") {
                        selection = .provider(model.addProvider())
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
            Text("Klucz w Keychain zostaje; usuniesz go w ustawieniach dostawcy przed skasowaniem.")
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
                ProviderDetailView(model: model, provider: $model.config.providers[idx])
                    .id(id)
            } else {
                ContentUnavailableView("Brak dostawcy", systemImage: "questionmark.circle")
            }
        case .routing: RoutingView(model: model)
        case .usage: UsageView(model: model)
        case .general, nil: GeneralView(model: model)
        }
    }

    @ViewBuilder
    private var errorBar: some View {
        if let message = model.loadError ?? model.saveError {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .padding(10)
                .glassEffect(.regular.tint(.red.opacity(0.25)), in: .rect(cornerRadius: 12))
                .padding(10)
        }
    }
}
