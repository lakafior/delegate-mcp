import DelegateCore
import SwiftUI

/// Agenci ACP: zainstalowani (stan logowania, aktualizacja, usuwanie) i dostępni z rejestru ACP.
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
            installedSection
            availableSection
        }
        .formStyle(.grouped)
        .navigationTitle("Agents")
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

    // MARK: zainstalowani

    @ViewBuilder
    private var installedSection: some View {
        Section {
            if model.installedAgents.isEmpty {
                Text("No agents installed. Install one below; Claude then gets the delegate_agent tool after a restart.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.installedAgents) { agent in
                InstalledAgentRow(model: model, agent: agent, latest: model.agentRegistry?.agent(agent.id))
            }
        } header: {
            Text("Installed")
        } footer: {
            Text("Agents analyse a read-only copy of a git repository in a macOS sandbox: they can't change your files or see your keys. The repository's tracked files are sent to the agent's cloud model, so its data region matters.")
        }
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
            Text("The same registry Zed and JetBrains IDEs use. Mac builds are verified by the registry's checksum or, without one, by the developer's code signature (unsigned ones only with your approval); npm agents are installed once with your Node.js into Delegate's folder (install scripts disabled) and run without npx. Agents that need uv come later.")
        }
    }
}

// MARK: wiersze

private struct InstalledAgentRow: View {
    let model: AppModel
    let agent: InstalledAgent
    let latest: ACPRegistry.Agent?

    private var check: AgentAccount.Check? { model.agentChecks[agent.id] }
    private var activity: String? { model.agentActivity[agent.id] }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentStatusDot(signIn: check?.signIn, busy: activity != nil)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name).font(.headline)
                Text(details).font(.callout).foregroundStyle(.secondary)
                if let activity {
                    Text(activity).font(.callout).foregroundStyle(.secondary)
                } else if case .failed(let why) = check?.signIn {
                    Text(why).font(.callout).foregroundStyle(.red).lineLimit(3)
                }
            }
            Spacer()
            if activity != nil {
                ProgressView().controlSize(.small)
            } else {
                actions
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Check again", systemImage: "arrow.clockwise") { model.checkAgent(agent.id) }
            Button("Remove", systemImage: "trash", role: .destructive) { model.uninstallAgent(agent.id) }
        }
    }

    private var details: String {
        var parts = ["v\(agent.version)", "data: \(AgentRegions.region(for: agent.id).title)"]
        switch agent.verifiedBy {
        case "signature": parts.append("signed by \(agent.signer ?? "a known developer")")
        case "trusted": parts.append("unverified, installed with your approval")
        default: break
        }
        switch check?.signIn {
        case .signedIn: parts.append("signed in")
        case .needsSignIn: parts.append("not signed in")
        case .failed: parts.append("check failed")
        case nil: break
        }
        if let check, !check.models.isEmpty {
            parts.append("models: " + check.models.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actions: some View {
        HStack {
            if case .needsSignIn(let methods) = check?.signIn {
                signInButton(methods)
            }
            if let latest, latest.version != agent.version {
                Button("Update to \(latest.version)") { model.installAgent(latest) }
            }
            Menu {
                Button("Check again", systemImage: "arrow.clockwise") { model.checkAgent(agent.id) }
                if let methods = check?.authMethods, !methods.isEmpty, check?.signIn == .signedIn {
                    Menu("Sign in again") {
                        ForEach(methods, id: \.id) { m in
                            Button(m.name) { model.signInAgent(agent.id, method: m) }
                        }
                    }
                }
                Divider()
                Button("Remove", systemImage: "trash", role: .destructive) { model.uninstallAgent(agent.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func signInButton(_ methods: [ACPAgentHello.AuthMethod]) -> some View {
        if methods.count == 1, let m = methods.first {
            Button(m.type == "terminal" ? "Sign in (Terminal)" : "Sign in") { model.signInAgent(agent.id, method: m) }
                .buttonStyle(.borderedProminent)
                .help(m.name)
        } else if !methods.isEmpty {
            Menu("Sign in") {
                ForEach(methods, id: \.id) { m in
                    Button(m.type == "terminal" ? "\(m.name) (Terminal)" : m.name) { model.signInAgent(agent.id, method: m) }
                }
            }
            .fixedSize()
        }
    }
}

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
