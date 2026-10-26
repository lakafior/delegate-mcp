import DelegateCore
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            recent
            Divider()
            providers
            actions
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            model.reloadIfChangedOnDisk()
            model.refresh()
            model.refreshUsage()
        }
        .onChange(of: model.config) { model.configChanged() }
    }

    // MARK: nagłówek: dzisiejsze użycie

    private var header: some View {
        let stats = model.usageStats
        return VStack(alignment: .leading, spacing: 4) {
            Label("Delegate", systemImage: "arrow.triangle.branch").font(.headline)
            HStack(spacing: 14) {
                Stat(value: "\(stats.callsToday)", label: "zadań dziś")
                Stat(value: stats.tokensToday.formatted(.number.notation(.compactName)), label: "tokenów dziś")
                Stat(value: "\(stats.callsWeek)", label: "w 7 dni")
                if stats.costToday > 0 {
                    Stat(value: String(format: "$%.2f", stats.costToday), label: "koszt dziś")
                }
            }
        }
    }

    // MARK: ostatnie delegacje

    @ViewBuilder
    private var recent: some View {
        let entries = model.usageStats.recent
        if entries.isEmpty {
            Text("Claude nie oddelegował jeszcze nic w tym tygodniu. Po zmianach zrestartuj Claude'a, żeby wczytał instrukcje serwera.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ostatnie delegacje").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                    RecentRow(entry: e)
                }
            }
        }
    }

    // MARK: dostawcy: jedna linia stanu, szczegóły w ustawieniach

    private var providers: some View {
        let enabled = model.config.providers.filter(\.enabled)
        let issues = enabled.filter { p in
            if case .failure = model.testResults[p.id] { return true }
            if case .missingKey = model.status(of: p) { return true }
            return false
        }
        return VStack(alignment: .leading, spacing: 4) {
            if enabled.isEmpty {
                Label("Brak włączonych dostawców", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if issues.isEmpty {
                Label("Gotowi dostawcy: \(enabled.count)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(issues) { p in
                    Label("\(p.id): \(issueText(p))", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            if model.isTestingAny {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Testuję połączenia…").foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }

    private func issueText(_ p: ProviderConfig) -> String {
        if case .failure(let e) = model.testResults[p.id] { return e.description }
        return model.status(of: p).label
    }

    private var actions: some View {
        HStack {
            Button("Testuj", systemImage: "bolt.badge.checkmark") { model.testAll() }
                .disabled(model.isTestingAny || model.config.providers.isEmpty)
            Spacer()
            Button("Ustawienia…", systemImage: "gearshape") {
                openWindow(id: SettingsWindow.id)
                NSApp.activate()
            }
            Button("Zakończ") { NSApp.terminate(nil) }
        }
        .buttonStyle(.glass)
    }
}

private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title3.bold().monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct RecentRow: View {
    let entry: UsageEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(entry.ok ? .green : .red)
                .font(.caption)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(entry.provider)/\(entry.model)").font(.callout).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(entry.ts, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let task = entry.task { parts.append(task) }
        let tokens = (entry.inputTokens ?? 0) + (entry.outputTokens ?? 0)
        if tokens > 0 { parts.append("\(tokens) tok.") }
        parts.append(String(format: "%.1f s", Double(entry.ms) / 1000))
        if !entry.ok, let error = entry.error { parts.append(error) }
        return parts.joined(separator: " · ")
    }
}
