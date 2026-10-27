import DelegateCore
import SwiftUI

/// Strona zainstalowanego agenta (jak strona dostawcy): stan logowania, weryfikacja, modele, aktualizacja, usuwanie.
struct AgentDetailView: View {
    let model: AppModel
    let agent: InstalledAgent
    let onRemoved: () -> Void
    @State private var confirmRemove = false

    private var check: AgentAccount.Check? { model.agentChecks[agent.id] }
    private var activity: String? { model.agentActivity[agent.id] }
    private var latest: ACPRegistry.Agent? { model.agentRegistry?.agent(agent.id) }

    var body: some View {
        Form {
            if let error = model.agentError {
                Section {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Spacer()
                        Button("Close") { model.agentError = nil }.controlSize(.small)
                    }
                }
            }
            statusSection
            defaultsSection
            detailsSection
            Section {
                Button("Remove \(agent.name)…", role: .destructive) { confirmRemove = true }
            } footer: {
                Text("Removing deletes the installed files. The agent's own sign-in data stays in its folder (\(stateFolders)).")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(agent.name)
        .confirmationDialog("Remove \(agent.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                model.uninstallAgent(agent.id)
                onRemoved()
            }
        }
        .onAppear { if check == nil { model.checkAgent(agent.id) } }
    }

    // MARK: stan

    private var statusText: String {
        if let activity { return activity }
        switch check?.signIn {
        case .signedIn: return "Signed in and working in the sandbox"
        case .needsSignIn: return "Not signed in"
        case .failed: return "Check failed"
        case nil: return "Not checked yet"
        }
    }

    private var statusSection: some View {
        Section {
            HStack(spacing: 10) {
                AgentStatusDot(signIn: check?.signIn, busy: activity != nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText).font(.headline)
                    if case .failed(let why) = check?.signIn {
                        Text(why).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                Spacer()
                if activity != nil {
                    ProgressView().controlSize(.small)
                } else {
                    if case .needsSignIn(let methods) = check?.signIn { signInButtons(methods, prominent: true) }
                    Button("Check again") { model.checkAgent(agent.id) }
                }
            }
            if check?.signIn == .signedIn, let methods = check?.authMethods, !methods.isEmpty {
                LabeledContent("Account") { signInButtons(methods, prominent: false, label: "Sign in again") }
            }
        } footer: {
            Text("The check starts the agent in the same sandbox as real tasks and opens a session; nothing is sent to its model.")
        }
    }

    @ViewBuilder
    private func signInButtons(_ methods: [ACPAgentHello.AuthMethod], prominent: Bool, label: String = "Sign in") -> some View {
        if methods.count == 1, let m = methods.first {
            let button = Button(m.type == "terminal" ? "\(label) (Terminal)" : label) { model.signInAgent(agent.id, method: m) }
                .help(m.name)
            if prominent { button.buttonStyle(.borderedProminent) } else { button }
        } else if !methods.isEmpty {
            Menu(label) {
                ForEach(methods, id: \.id) { m in
                    Button(m.type == "terminal" ? "\(m.name) (Terminal)" : m.name) { model.signInAgent(agent.id, method: m) }
                }
            }
            .fixedSize()
        }
    }

    // MARK: domyślne opcje

    private var settings: AgentSettings? { model.config.agentSettings(agent.id) }

    private func binding(_ keyPath: KeyPath<AgentSettings, String?>) -> Binding<String> {
        Binding(
            get: { settings?[keyPath: keyPath] ?? "" },
            set: { value in
                var modelValue = settings?.model, effortValue = settings?.effort
                if keyPath == \AgentSettings.model { modelValue = value } else { effortValue = value }
                model.config.setAgent(agent.id, model: modelValue, effort: effortValue)
            })
    }

    @ViewBuilder
    private var defaultsSection: some View {
        if let check, !check.models.isEmpty || !check.efforts.isEmpty {
            Section {
                if !check.models.isEmpty {
                    Picker("Model", selection: binding(\.model)) {
                        Text("Agent's default\(check.defaultModel.map { " (\($0))" } ?? "")").tag("")
                        ForEach(options(check.models, current: settings?.model), id: \.self) { Text($0).tag($0) }
                    }
                }
                if !check.efforts.isEmpty {
                    Picker("Effort", selection: binding(\.effort)) {
                        Text("Agent's default\(check.defaultEffort.map { " (\($0))" } ?? "")").tag("")
                        ForEach(options(check.efforts, current: settings?.effort), id: \.self) { Text($0).tag($0) }
                    }
                }
            } header: {
                Text("Defaults for delegated tasks")
            } footer: {
                Text("Used when the assistant doesn't pick a model or effort itself. A cheaper model saves your plan's limits: for example Claude Agent on haiku with low effort costs a fraction of what the assistant's own model would.")
            }
        }
    }

    /// Wartości od agenta; zapisana wartość, której agent już nie ogłasza, zostaje na liście, żeby jej nie zgubić.
    private func options(_ values: [String], current: String?) -> [String] {
        let real = values.filter { $0 != "default" }
        guard let current, !current.isEmpty, !real.contains(current) else { return real }
        return real + [current]
    }

    // MARK: szczegóły

    private var detailsSection: some View {
        Section("Details") {
            LabeledContent("Version") {
                HStack {
                    Text(agent.version)
                    if let latest, latest.version != agent.version {
                        Button("Update to \(latest.version)") { model.installAgent(latest) }
                            .disabled(activity != nil)
                    }
                }
            }
            LabeledContent("Data region") {
                Text(AgentRegions.region(for: agent.id).title)
            }
            LabeledContent("Verified by") { Text(verification) }
            if let check, !check.models.isEmpty {
                LabeledContent("Models") {
                    Text(check.models.map { $0 == check.defaultModel ? "\($0) (default)" : $0 }.joined(separator: ", "))
                        .multilineTextAlignment(.trailing)
                }
            }
            LabeledContent("Runs") {
                Text(([agent.executable] + agent.args).joined(separator: " "))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
            LabeledContent("Can write to") {
                Text(stateFolders).font(.caption.monospaced()).multilineTextAlignment(.trailing)
            }
            LabeledContent("Installed", value: agent.installedAt.formatted(date: .abbreviated, time: .shortened))
        }
    }

    private var verification: String {
        switch agent.verifiedBy {
        case "checksum": "registry checksum (SHA-256)"
        case "signature": "code signature: \(agent.signer ?? "Developer ID")"
        case "npm": "npm package integrity"
        case "trusted": "nothing — installed with your approval"
        default: currentSignature
        }
    }

    /// Dla instalacji sprzed weryfikacji: podpis programu sprawdzony teraz.
    private var currentSignature: String {
        let target = agent.kind == "npm" ? agent.args.first.map(URL.init(fileURLWithPath:)) : URL(fileURLWithPath: agent.executable)
        guard let target else { return "unknown" }
        let sig = CodeSignature.check(target)
        return sig.isDeveloperID ? "code signature: \(sig.publisher ?? "Developer ID") (checked now)" : "not recorded (installed by an older version)"
    }

    private var stateFolders: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return AgentSandbox.stateDirectories(forAgent: agent.id, kind: agent.kind, home: FileManager.default.homeDirectoryForCurrentUser)
            .map { $0.path.replacingOccurrences(of: home, with: "~") }
            .joined(separator: ", ")
    }
}
