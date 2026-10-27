import AppKit
import DelegateCore
import SwiftUI

/// Pierwszy ekran: czy wszystko działa, podpięcie w Claude, diagnostyka i dostawcy w jednym miejscu.
struct OverviewView: View {
    @Bindable var model: AppModel
    @State private var copied = false

    var body: some View {
        Form {
            Section { summary }
            claude
            if let report = model.diagnostics {
                Section("System") {
                    ForEach(report.checks.filter { $0.group == .system }) { checkRow($0) }
                }
                Section("Providers") {
                    ForEach(report.providers) { providerRow($0) }
                }
            }
            if !model.installedAgents.isEmpty { agentsSection }
        }
        .formStyle(.grouped)
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItemGroup {
                if let report = model.diagnostics {
                    Button(copied ? "Copied" : "Copy report", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.terminalOutput(), forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    }
                }
                Button("Check again", systemImage: "arrow.clockwise") {
                    model.runDiagnostics()
                    model.checkAllAgents()
                }
                    .disabled(model.diagnosing)
            }
        }
        .task {
            model.refreshUsage()
            if model.diagnostics == nil { model.runDiagnostics() }
        }
    }

    // MARK: podsumowanie

    private var summary: some View {
        let severities = (model.diagnostics?.checks.map(\.severity) ?? []) + (model.diagnostics?.providers.map(\.severity) ?? [])
            + model.agentSeverities
        let errors = severities.filter { $0 == .error }.count
        let warnings = severities.filter { $0 == .warning }.count
        let stats = model.usageStats
        return HStack(spacing: 12) {
            Group {
                if model.diagnostics == nil {
                    ProgressView().controlSize(.regular)
                } else {
                    Image(systemName: errors > 0 ? "xmark.octagon.fill" : (warnings > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"))
                        .foregroundStyle(errors > 0 ? .red : (warnings > 0 ? .orange : .green))
                }
            }
            .font(.title)
            .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.diagnostics == nil ? "Checking server, keys and connections…"
                     : errors > 0 ? "There are errors to fix"
                     : warnings > 0 ? "Working, with notes" : "Everything works")
                    .font(.headline)
                Text("Claude delegated \(stats.callsWeek) tasks in 7 days, \(stats.callsToday) today.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.diagnosing, model.diagnostics != nil { ProgressView().controlSize(.small) }
        }
    }

    // MARK: Claude

    private var claude: some View {
        Section {
            IntegrationRow(
                title: "Claude Desktop", state: model.desktopState, enabled: model.helperExists,
                install: { model.installDesktop(true); model.runDiagnostics() },
                remove: { model.installDesktop(false); model.runDiagnostics() })
            IntegrationRow(
                title: "Claude Code", state: model.codeState, enabled: model.helperExists,
                install: { Task { await model.installCode(true); model.runDiagnostics() } },
                remove: { Task { await model.installCode(false); model.runDiagnostics() } })
            LabeledContent {
                HStack {
                    Text(model.instructionsOutdated ? "older version" : (model.instructionsInstalled ? "up to date" : "none"))
                        .foregroundStyle(model.instructionsOutdated ? .orange : .secondary)
                    if model.instructionsInstalled {
                        if model.instructionsOutdated { Button("Update") { model.installInstructions(true) } }
                        Button("Remove") { model.installInstructions(false) }
                    } else {
                        Button("Add") { model.installInstructions(true) }
                    }
                }
            } label: {
                Text("Reminder in ~/.claude/CLAUDE.md")
                Text("Optional: the server provides instructions to Claude itself.")
            }
            LabeledContent {
                HStack {
                    switch model.swarmSkillState {
                    case .installed:
                        Text("installed").foregroundStyle(.secondary)
                        Button("Remove") { model.installSwarmSkill(false) }
                    case .outdated:
                        Text("older version").foregroundStyle(.orange)
                        Button("Update") { model.installSwarmSkill(true) }
                        Button("Remove") { model.installSwarmSkill(false) }
                    case .notInstalled:
                        Text("none").foregroundStyle(.secondary)
                        Button("Add") { model.installSwarmSkill(true) }
                    case .foreign:
                        Text("another skill uses this name").foregroundStyle(.orange)
                    }
                }
            } label: {
                Text("Skill /swarm in Claude Code")
                Text("Conductor mode: split a goal into tasks, run them on agents in parallel, review and merge.")
            }
            LabeledContent {
                Button("Allow") { model.apply(.authorizeKeys) }
                    .disabled(!model.helperExists)
            } label: {
                Text("Server access to keys")
                Text(keyAccessText)
            }
            if let message = model.integrationMessage {
                Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            if !model.helperExists {
                Label("delegate-mcp not found next to the app. Build everything with scripts/build-app.sh.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
        } header: {
            Text("Claude")
        } footer: {
            Text("Connecting Desktop or Code is enough. After provider changes, restart Claude so it loads the new instructions.")
        }
    }

    private var keyAccessText: String {
        guard let check = model.diagnostics?.checks.first(where: { $0.fix == .authorizeKeys || $0.name == "Server access to keys" })
        else { return "When macOS asks for a password while the server uses keys." }
        return check.message
    }

    // MARK: agenci

    private var agentsSection: some View {
        Section {
            if !AgentSandbox.isAvailable {
                checkRow(DiagnosticCheck(name: "Sandbox", severity: .error,
                                         message: "sandbox-exec is missing, so agents can't run."))
            }
            if model.installedAgents.contains(where: { $0.kind == "npm" }) {
                if let node = model.nodeRuntime {
                    checkRow(DiagnosticCheck(name: "Node.js", severity: .ok,
                                             message: "\(node.version) at \(node.node.path)"))
                } else {
                    checkRow(DiagnosticCheck(name: "Node.js", severity: .error,
                                             message: "Not found; npm agents won't start. Install it (brew install node)."))
                }
            }
            ForEach(model.installedAgents) { agent in agentRow(agent) }
        } header: {
            Text("Agents")
        } footer: {
            Text("Each check starts the agent in its sandbox and opens a session, without sending anything to its model. Claude sees only agents installed before its session started; restart Claude after installing one.")
        }
    }

    private func agentRow(_ agent: InstalledAgent) -> some View {
        let check = model.agentChecks[agent.id]
        let activity = model.agentActivity[agent.id]
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            switch check?.signIn {
            case .signedIn: SeverityIcon(severity: .ok)
            case .needsSignIn: SeverityIcon(severity: .warning)
            case .failed: SeverityIcon(severity: .error)
            case nil: ProgressView().controlSize(.mini)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                Group {
                    if let activity {
                        Text(activity)
                    } else {
                        switch check?.signIn {
                        case .signedIn: Text("Signed in, works in the sandbox · v\(agent.version)")
                        case .needsSignIn: Text("Not signed in")
                        case .failed(let why): Text(why).foregroundStyle(.red)
                        case nil: Text("Checking…")
                        }
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }
            Spacer()
            if activity == nil, case .needsSignIn(let methods) = check?.signIn, let m = methods.first {
                Button(m.type == "terminal" ? "Sign in (Terminal)" : "Sign in") { model.signInAgent(agent.id, method: m) }
                    .controlSize(.small)
            }
        }
    }

    // MARK: wiersze diagnostyki

    private func checkRow(_ check: DiagnosticCheck) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SeverityIcon(severity: check.severity)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.name)
                Text(check.message).font(.callout).foregroundStyle(.secondary)
                if let detail = check.detail {
                    Text(detail).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                }
            }
            Spacer()
            if let fix = check.fix {
                Button(fix.title) { model.apply(fix) }
                    .controlSize(.small)
                    .disabled(model.diagnosing)
            }
        }
    }

    private func providerRow(_ p: ProviderDiagnostic) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SeverityIcon(severity: p.severity)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.providerID).font(.body.monospaced())
                Text(p.error ?? p.status)
                    .font(.callout)
                    .foregroundStyle(p.error == nil ? Color.secondary : Color.red)
                    .lineLimit(3)
            }
            Spacer()
            if let ms = p.responseTimeMs {
                Text("\(ms) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SeverityIcon: View {
    let severity: DiagnosticSeverity

    var body: some View {
        switch severity {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .error: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

private struct IntegrationRow: View {
    let title: String
    let state: IntegrationState
    let enabled: Bool
    let install: () -> Void
    let remove: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(state.label).foregroundStyle(state == .installed ? .green : (state == .notInstalled ? .secondary : .orange))
                switch state {
                case .installed:
                    Button("Disconnect", action: remove)
                case .notInstalled:
                    Button("Connect", action: install).disabled(!enabled)
                case .stale:
                    Button("Repair", action: install).disabled(!enabled)
                }
            }
        }
    }
}

extension DiagnosticFix {
    var title: String {
        switch self {
        case .installDesktop, .installCode: "Connect"
        case .updateInstructions: "Add / update"
        case .authorizeKeys: "Allow"
        }
    }
}
