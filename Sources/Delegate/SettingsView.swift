import DelegateCore
import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case provider(String)
    case routing
    /// Przeglądanie rejestru ACP.
    case agents
    case agent(String)
    case usage
    case settings
}

extension SidebarItem {
    /// `--select=overview|routing|usage|settings|<id dostawcy>`: do ręcznego sprawdzania widoków.
    static func fromLaunchArguments() -> SidebarItem? {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--select=") }) else { return nil }
        switch arg.dropFirst("--select=".count) {
        case "overview", "diagnostics": return .overview
        case "routing": return .routing
        case "agents": return .agents
        case let s where s.hasPrefix("agent:"): return .agent(String(s.dropFirst("agent:".count)))
        case "usage": return .usage
        case "settings", "general": return .settings
        case let id: return .provider(String(id))
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var selection: SidebarItem? = SidebarItem.fromLaunchArguments() ?? .overview
    @State private var pendingDelete: String?
    @State private var renamingProvider: String?
    @State private var renameDraft = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                // Bez `.badge`: na macOS blokował zaznaczenie wiersza, gdy było wybrane coś innego.
                Label {
                    HStack {
                        Text("Overview")
                        Spacer()
                        if model.hasProviderIssues {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("Some providers need attention")
                        }
                    }
                } icon: {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                }
                .tag(SidebarItem.overview)
                Section("Providers (order = priority)") {
                    if model.config.providers.isEmpty {
                        Text("No providers. Add one with the + button.")
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
                            Button("Rename…", systemImage: "pencil") {
                                renameDraft = p.id
                                renamingProvider = p.id
                            }
                            Button("Delete \"\(p.id)\"", role: .destructive) { pendingDelete = p.id }
                        }
                    }
                    .onMove { model.config.providers.move(fromOffsets: $0, toOffset: $1) }
                }
                Section("Agents") {
                    ForEach(model.installedAgents) { agent in
                        Label {
                            Text(agent.name)
                        } icon: {
                            AgentStatusDot(signIn: model.agentChecks[agent.id]?.signIn, busy: model.agentActivity[agent.id] != nil)
                        }
                        .tag(SidebarItem.agent(agent.id))
                        .contextMenu {
                            Button("Check again", systemImage: "arrow.clockwise") { model.checkAgent(agent.id) }
                        }
                    }
                    Label("Browse agents", systemImage: "square.grid.2x2").tag(SidebarItem.agents)
                }
                Section("App") {
                    Label("Routing", systemImage: "arrow.triangle.branch").tag(SidebarItem.routing)
                    Label("Usage", systemImage: "chart.bar").tag(SidebarItem.usage)
                    Label("Settings", systemImage: "gearshape").tag(SidebarItem.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240)
            .toolbar {
                ToolbarItem {
                    Menu("Add provider", systemImage: "plus") {
                        ForEach(ProviderPreset.all) { preset in
                            Button {
                                selection = .provider(model.addProvider(from: preset))
                            } label: {
                                Label(preset.title, systemImage: preset.kind.symbol)
                            }
                        }
                        Divider()
                        Button("Browse agents…", systemImage: "square.grid.2x2") { selection = .agents }
                    }
                }
            }
        } detail: {
            detail
        }
        .confirmationDialog(
            "Delete provider \"\(pendingDelete ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDelete {
                    selection = .overview
                    model.removeProvider(id: id)
                }
                pendingDelete = nil
            }
        } message: {
            Text("This provider's API key will be removed from Keychain.")
        }
        .alert(
            "Rename provider",
            isPresented: Binding(get: { renamingProvider != nil }, set: { if !$0 { renamingProvider = nil } })
        ) {
            TextField("New identifier", text: $renameDraft)
            Button("Cancel", role: .cancel) { renamingProvider = nil }
            Button("Rename") {
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
            Text("Enter a new unique provider identifier.")
        }
        .onChange(of: model.config) { model.configChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reloadIfChangedOnDisk()
            model.refresh()
        }
        .safeAreaInset(edge: .bottom) { errorBar }
        .task { await model.loadAgents() }
        .confirmationDialog(
            "Install \(model.unverifiedAgent?.agent.name ?? "agent") without verification?",
            isPresented: Binding(get: { model.unverifiedAgent != nil }, set: { if !$0 { model.unverifiedAgent = nil } }),
            titleVisibility: .visible
        ) {
            Button("Install anyway", role: .destructive) { model.installAgentAnyway() }
            Button("Cancel", role: .cancel) { model.unverifiedAgent = nil }
        } message: {
            if let pending = model.unverifiedAgent {
                Text("The registry publishes no checksum for it and the program isn't signed by a known developer\(pending.error.signer.map { " (signature: \($0))" } ?? ""). It will still run only in the sandbox. Download SHA-256: \(pending.error.sha256.prefix(16))…; a different file for the same version will be refused later.")
            }
        }
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
                ContentUnavailableView("No provider", systemImage: "questionmark.circle")
            }

        case .routing: RoutingView(model: model)
        case .agents: AgentsView(model: model)
        case .agent(let id):
            if let agent = model.installedAgents.first(where: { $0.id == id }) {
                AgentDetailView(model: model, agent: agent, onRemoved: { selection = .agents })
                    .id(id)
            } else {
                ContentUnavailableView("Agent not installed", systemImage: "questionmark.circle")
            }
        case .usage: UsageView(model: model)
        case .settings: GeneralView(model: model)
        case .overview, nil: OverviewView(model: model)
        }
    }

    @ViewBuilder
    private var errorBar: some View {
        if let err = model.saveError ?? model.loadError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(err).font(.callout).lineLimit(2)
                Spacer()
                Button("Close") {
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
