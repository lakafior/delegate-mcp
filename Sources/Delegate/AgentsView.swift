import DelegateCore
import SwiftUI

/// Rejestr agentów ACP: dostępni do instalacji. Zainstalowani mają swoje strony w pasku bocznym (`AgentDetailView`).
struct AgentsView: View {
    @Bindable var model: AppModel
    @State private var search = ""

    var body: some View {
        Form {
            if let error = model.agentError {
                Section {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Close") { model.agentError = nil }.controlSize(.small)
                    }
                }
            }
            availableSection
        }
        .formStyle(.grouped)
        .navigationTitle("Browse agents")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.loadAgents(forceRefresh: true) }
                } label: {
                    Label("Refresh registry", systemImage: "arrow.clockwise")
                }
                .disabled(model.loadingAgentRegistry)
                .help("Download the current ACP agent registry")
            }
        }
        .task { await model.loadAgents() }
    }

    // MARK: dostępni

    private var available: [ACPRegistry.Agent] {
        let installed = Set(model.installedAgents.map(\.id))
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return (model.agentRegistry?.agents ?? [])
            .filter { !installed.contains($0.id) }
            .filter { query.isEmpty || $0.name.lowercased().contains(query) || ($0.description ?? "").lowercased().contains(query) }
            .sorted { a, b in
                let ia = a.installBlocker(node: model.nodeRuntime) == nil, ib = b.installBlocker(node: model.nodeRuntime) == nil
                return ia != ib ? ia : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    @ViewBuilder
    private var availableSection: some View {
        Section {
            TextField("Search agents", text: $search)
            if model.agentRegistry == nil {
                HStack {
                    if model.loadingAgentRegistry { ProgressView().controlSize(.small) }
                    Text(model.loadingAgentRegistry ? "Loading the registry…" : "Registry not loaded.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(available) { agent in
                AvailableAgentRow(model: model, agent: agent)
            }
        } header: {
            Text("Available from the ACP registry")
        } footer: {
            Text("Installed agents appear in the sidebar. Agents analyse a read-only copy of a git repository in a macOS sandbox; the repository's tracked files go to the agent's cloud model, so its data region matters. This is the same registry Zed and JetBrains IDEs use. Mac builds are verified by the registry's checksum or, without one, by the developer's code signature (unsigned ones only with your approval); npm agents are installed once with your Node.js into Delegate's folder (install scripts disabled) and run without npx. Agents that need uv come later.")
        }
    }
}

// MARK: wiersze

private struct AvailableAgentRow: View {
    let model: AppModel
    let agent: ACPRegistry.Agent

    private var sourceLine: String {
        var s = "data: \(AgentRegions.region(for: agent.id).title)"
        if case .binary(let t) = agent.installKind, (t.sha256 ?? "").isEmpty {
            s += " · no checksum in the registry, checked by code signature on install"
        }
        if case .npm(let p) = agent.installKind {
            s += " · npm \(p.package)"
            if let node = model.nodeRuntime { s += " (Node \(node.version))" }
        }
        return s
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.name).font(.headline)
                    Text("v\(agent.version)").font(.caption).foregroundStyle(.secondary)
                }
                if let d = agent.description {
                    Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(sourceLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let activity = model.agentActivity[agent.id] {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(activity).font(.callout).foregroundStyle(.secondary)
                }
            } else if let blocker = agent.installBlocker(node: model.nodeRuntime) {
                Text(blocker).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            } else {
                Button("Install") { model.installAgent(agent) }
            }
        }
        .padding(.vertical, 2)
    }
}

struct AgentStatusDot: View {
    let signIn: AgentSignIn?
    let busy: Bool

    private var color: Color {
        if busy { return .secondary }
        switch signIn {
        case .signedIn: return .green
        case .needsSignIn: return .orange
        case .failed: return .red
        case nil: return .secondary
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
    }
}

extension ACPRegistry.Agent {
    /// Dlaczego nie da się zainstalować (do pokazania zamiast przycisku); `nil` = można.
    func installBlocker(node: NodeRuntime?) -> String? {
        switch installKind {
        case .binary:
            return nil
        case .npm:
            return node == nil ? "Needs Node.js" : nil
        case .needsRuntime(let tool):
            return "Needs \(tool)"
        case .unavailable:
            return "No Mac build"
        }
    }
}
