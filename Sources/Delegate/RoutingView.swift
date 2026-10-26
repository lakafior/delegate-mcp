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
                Text("Własne zasady globalne")
            } footer: {
                Text("Doklejane do instrukcji serwera. Ogólne zasady delegowania serwer podaje sam; reguły dla jednego dostawcy wpisz w jego „Wskazówkach dla Claude'a”. Najlepiej po angielsku.")
            }
            Section("Limity") {
                Stepper(value: $model.config.timeoutSeconds, in: 10...600, step: 10) {
                    LabeledContent("Limit czasu jednego wywołania", value: "\(Int(model.config.timeoutSeconds)) s")
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
            Picker("Tryb delegowania", selection: $model.config.delegationMode) {
                ForEach(DelegationMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Jak chętnie delegować")
        } footer: {
            Text(model.config.delegationMode.explanation + " Zmienia ton instrukcji serwera; działa po restarcie Claude'a.")
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
            Text("Dane osobiste i z pracy mogą trafić do")
        } footer: {
            Text("Claude oznacza zadanie jako publiczne, osobiste albo prywatne, a serwer pilnuje regionów: osobiste tylko do zaznaczonych, prywatne wyłącznie do modeli lokalnych. Region dostawcy zmienisz w jego ustawieniach.")
        }
    }

    private func providers(in region: PrivacyRegion) -> String {
        let ids = model.config.providers.filter { $0.effectivePrivacy == region }.map(\.id)
        return ids.isEmpty ? "brak dostawców" : ids.joined(separator: ", ")
    }

    // MARK: budżet

    private var budgetSection: some View {
        Section {
            Toggle("Dzienny limit na płatne modele", isOn: Binding(
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
            LabeledContent("Wydano dziś", value: String(format: "$%.4f", model.usageStats.costToday))
        } header: {
            Text("Budżet")
        } footer: {
            Text("Po przekroczeniu limitu serwer używa tylko darmowych i lokalnych modeli. Model bez znanej ceny liczy się jako płatny.")
        }
    }

    // MARK: podgląd

    private var previewSection: some View {
        let request = DelegateRequest(prompt: previewPrompt, task: previewTask.isEmpty ? nil : previewTask,
                                      sensitivity: previewSensitivity)
        let plan = model.routingPlan(for: request)
        let leak = SecretLeakDetector.scan(previewPrompt)
        return Section {
            TextField("Treść zadania (opcjonalnie, do sprawdzenia sekretów)", text: $previewPrompt, axis: .vertical)
                .lineLimit(1...4)
            Picker("Tag zadania", selection: $previewTask) {
                Text("bez tagu (wg priorytetu)").tag("")
                ForEach(allTags, id: \.self) { Text($0).tag($0) }
            }
            Picker("Dane", selection: $previewSensitivity) {
                ForEach(Sensitivity.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if let leak, plan.candidates.contains(where: { $0.provider.effectivePrivacy != .local }) {
                Label("Serwer zablokuje: wykryto \(leak.type) (\(leak.matched)).", systemImage: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(.red)
            }
            if plan.candidates.isEmpty {
                Label("Żaden model nie przyjmie tego zadania.", systemImage: "xmark.octagon").foregroundStyle(.red)
            } else {
                ForEach(Array(plan.candidates.prefix(5).enumerated()), id: \.offset) { i, c in
                    LabeledContent("\(i + 1). \(c.ref)") {
                        Text("\(c.provider.effectivePrivacy.title) · \(c.model.shortCost)").foregroundStyle(.secondary)
                    }
                }
                if plan.candidates.count > 5 {
                    Text("…i \(plan.candidates.count - 5) kolejnych jako fallback").font(.callout).foregroundStyle(.secondary)
                }
            }
            if !plan.excluded.isEmpty {
                DisclosureGroup("Pominięte (\(plan.excluded.count))") {
                    ForEach(Array(plan.excluded.enumerated()), id: \.offset) { _, e in
                        LabeledContent(e.ref) { Text(e.reason).foregroundStyle(.secondary) }
                    }
                }
            }
        } header: {
            Text("Podgląd: który model dostałby zadanie")
        } footer: {
            Text("Ta sama logika co w serwerze, bez wysyłania czegokolwiek. Tryb i instrukcje wpływają na to, czy Claude w ogóle deleguje; tu widać, dokąd zadanie trafi.")
        }
    }

    private var allTags: [String] {
        var seen = Set<String>()
        return model.config.providers.flatMap { $0.models.flatMap(\.tags) }.map { $0.lowercased() }
            .filter { seen.insert($0).inserted }
    }
}
