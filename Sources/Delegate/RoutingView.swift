import DelegateCore
import SwiftUI

struct RoutingView: View {
    @Bindable var model: AppModel
    @State private var previewPrompt = ""
    @State private var previewTask = ""
    @State private var previewSensitivity: Sensitivity = .public

    var body: some View {
        Form {
            modeSection
            privacySection
            budgetSection
            previewSection
            Section {
                TextEditor(text: $model.config.routingGuidance)
                    .font(.body)
                    .frame(minHeight: 80)
            } header: {
                Text("Custom global rules")
            } footer: {
                Text("Added to the server instructions. The server provides the general delegation rules itself; put rules for a single provider in its \"Guidance for Claude\". English works best.")
            }
            Section("Limits") {
                Stepper(value: $model.config.timeoutSeconds, in: 10...600, step: 10) {
                    LabeledContent("Timeout per call", value: "\(Int(model.config.timeoutSeconds)) s")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Routing")
        .onAppear { model.refreshUsage() }
    }

    // MARK: tryb

    private var modeSection: some View {
        Section {
            Picker("Delegation mode", selection: $model.config.delegationMode) {
                ForEach(DelegationMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("How eagerly to delegate")
        } footer: {
            Text(model.config.delegationMode.explanation + " Changes the tone of the server instructions; takes effect after restarting Claude.")
        }
    }

    // MARK: prywatność

    private var privacySection: some View {
        Section {
            ForEach([PrivacyRegion.local, .eu, .us, .cn, .other], id: \.self) { region in
                Toggle(isOn: Binding(
                    get: { model.config.personalRegions.contains(region) },
                    set: { on in
                        if on { if !model.config.personalRegions.contains(region) { model.config.personalRegions.append(region) } }
                        else { model.config.personalRegions.removeAll { $0 == region } }
                    })) {
                    Text(region.title)
                    Text(providers(in: region))
                }
            }
        } header: {
            Text("Personal and work data may go to")
        } footer: {
            Text("Claude marks each task as public, personal or private, and the server enforces regions: personal tasks only go to the selected ones, private tasks only to local models. Change a provider's region in its settings.")
        }
    }

    private func providers(in region: PrivacyRegion) -> String {
        let ids = model.config.providers.filter { $0.effectivePrivacy == region }.map(\.id)
        return ids.isEmpty ? "no providers" : ids.joined(separator: ", ")
    }

    // MARK: budżet

    private var budgetSection: some View {
        Section {
            Toggle("Daily limit for paid models", isOn: Binding(
                get: { model.config.dailyBudgetUSD != nil },
                set: { model.config.dailyBudgetUSD = $0 ? (model.config.dailyBudgetUSD ?? 1) : nil }))
            if model.config.dailyBudgetUSD != nil {
                LabeledContent("Limit (USD)") {
                    TextField("Limit", value: Binding(
                        get: { model.config.dailyBudgetUSD ?? 0 },
                        set: { model.config.dailyBudgetUSD = max(0, $0) }), format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
            }
            LabeledContent("Spent today", value: String(format: "$%.4f", model.usageStats.costToday))
        } header: {
            Text("Budget")
        } footer: {
            Text("Once the limit is exceeded, the server uses only free and local models. A model with no known price counts as paid.")
        }
    }

    // MARK: podgląd

    private var previewSection: some View {
        let request = DelegateRequest(prompt: previewPrompt, task: previewTask.isEmpty ? nil : previewTask,
                                      sensitivity: previewSensitivity)
        let plan = model.routingPlan(for: request)
        let leak = SecretLeakDetector.scan(previewPrompt)
        return Section {
            TextField("Task content (optional, for checking secrets)", text: $previewPrompt, axis: .vertical)
                .lineLimit(1...4)
            Picker("Task tag", selection: $previewTask) {
                Text("no tag (by priority)").tag("")
                ForEach(allTags, id: \.self) { Text($0).tag($0) }
            }
            Picker("Data", selection: $previewSensitivity) {
                ForEach(Sensitivity.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if let leak, plan.candidates.contains(where: { $0.provider.effectivePrivacy != .local }) {
                Label("Server will block: detected \(leak.type) (\(leak.matched)).", systemImage: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(.red)
            }
            if plan.candidates.isEmpty {
                Label("No model will accept this task.", systemImage: "xmark.octagon").foregroundStyle(.red)
            } else {
                ForEach(Array(plan.candidates.prefix(5).enumerated()), id: \.offset) { i, c in
                    LabeledContent("\(i + 1). \(c.ref)") {
                        Text("\(c.provider.effectivePrivacy.title) · \(c.model.shortCost)").foregroundStyle(.secondary)
                    }
                }
                if plan.candidates.count > 5 {
                    Text("…and \(plan.candidates.count - 5) more as fallback").font(.callout).foregroundStyle(.secondary)
                }
            }
            if !plan.excluded.isEmpty {
                DisclosureGroup("Skipped (\(plan.excluded.count))") {
                    ForEach(Array(plan.excluded.enumerated()), id: \.offset) { _, e in
                        LabeledContent(e.ref) { Text(e.reason).foregroundStyle(.secondary) }
                    }
                }
                if plan.excluded.contains(where: { $0.reason.hasPrefix("paused until") }) {
                    Button("Resume paused models") { model.clearCooldowns() }
                        .help("Models that just failed (quota, overload, unsupported) are skipped for a while. Resume them, e.g. after topping up or enabling billing.")
                }
            }
        } header: {
            Text("Preview: which model would get the task")
        } footer: {
            Text("Same logic as the server, without sending anything. The mode and instructions affect whether Claude delegates at all; here you see where a task would go.")
        }
    }

    private var allTags: [String] {
        var seen = Set<String>()
        return model.config.providers.flatMap { $0.models.flatMap(\.tags) }.map { $0.lowercased() }
            .filter { seen.insert($0).inserted }
    }
}
