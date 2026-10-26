import AppKit
import Charts
import DelegateCore
import SwiftUI
import UniformTypeIdentifiers

struct UsageView: View {
    let model: AppModel
    @State private var days = 7
    @State private var entries: [UsageEntry] = []

    private struct DayBar: Identifiable {
        let id = UUID()
        let day: Date
        let model: String
        let tokens: Int
    }

    private var bars: [DayBar] {
        let cal = Calendar.current
        var sums: [String: Int] = [:]
        var dayOf: [String: Date] = [:]
        for e in entries {
            let day = cal.startOfDay(for: e.ts)
            let ref = "\(e.provider)/\(e.model)"
            let key = "\(day.timeIntervalSince1970)|\(ref)"
            sums[key, default: 0] += (e.inputTokens ?? 0) + (e.outputTokens ?? 0)
            dayOf[key] = day
        }
        var result: [DayBar] = []
        for (key, tokens) in sums {
            guard let day = dayOf[key], let ref = key.split(separator: "|").last else { continue }
            result.append(DayBar(day: day, model: String(ref), tokens: tokens))
        }
        return result
    }

    private struct ModelRowData: Identifiable {
        var id: String { ref }
        var ref: String
        var calls = 0
        var failed = 0
        var input = 0
        var output = 0
        var cost: Double = 0.0
        /// Czy którekolwiek wywołanie miało znany koszt.
        var priced = false
    }

    private var byModel: [ModelRowData] {
        var rows: [String: ModelRowData] = [:]
        for e in entries {
            let ref = "\(e.provider)/\(e.model)"
            var row = rows[ref] ?? ModelRowData(ref: ref)
            row.calls += 1
            if !e.ok { row.failed += 1 }
            row.input += e.inputTokens ?? 0
            row.output += e.outputTokens ?? 0
            row.cost += e.costUSD ?? 0.0
            if e.costUSD != nil { row.priced = true }
            rows[ref] = row
        }
        return rows.values.sorted { $0.calls > $1.calls }
    }

    private var totalTokens: Int {
        entries.reduce(0) { $0 + ($1.inputTokens ?? 0) + ($1.outputTokens ?? 0) }
    }

    private var totalCost: Double {
        entries.compactMap(\.costUSD).reduce(0, +)
    }

    private var totalSavings: Double { CostCalculator.savingsVsSonnet(entries) }

    /// Udane wywołania modeli bez ceny (np. kategoria „tani” bez kwot): nie wchodzą do kosztu ani oszczędności.
    private var unpricedCount: Int { entries.filter { $0.ok && $0.costUSD == nil }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Picker("Zakres", selection: $days) {
                        Text("7 dni").tag(7)
                        Text("30 dni").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)

                    Spacer()

                    Menu {
                        Button("Eksportuj CSV...") { exportCSV() }
                        Button("Eksportuj JSON...") { exportJSON() }
                    } label: {
                        Label("Eksportuj", systemImage: "square.and.arrow.up")
                    }
                    .disabled(entries.isEmpty)
                }

                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        StatTile(title: "Wywołania", value: "\(entries.count)")
                        StatTile(title: "Tokeny", value: totalTokens.formatted())
                        StatTile(title: "Błędy", value: "\(entries.filter { !$0.ok }.count)")
                    }
                    HStack(spacing: 12) {
                        StatTile(title: "Koszt", value: String(format: "$%.4f", totalCost))
                        StatTile(title: "Zaoszczędzono vs Sonnet", value: String(format: "~$%.2f", totalSavings))
                    }
                }
                if unpricedCount > 0 {
                    Label("\(unpricedCount) wywołań modeli bez podanej ceny nie wlicza się do kosztu ani oszczędności. Ustaw kwoty w ustawieniach dostawcy.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if entries.isEmpty {
                    ContentUnavailableView("Brak danych", systemImage: "chart.bar", description: Text("Użycie pojawi się po pierwszych delegowanych zadaniach."))
                } else {
                    Chart(bars) { bar in
                        BarMark(x: .value("Dzień", bar.day, unit: .day), y: .value("Tokeny", bar.tokens))
                            .foregroundStyle(by: .value("Model", bar.model))
                    }
                    .frame(height: 220)

                    ForEach(byModel) { row in
                        HStack {
                            Text(row.ref).font(.body.monospaced())
                            Spacer()
                            let costStr = row.priced ? String(format: " · $%.4f", row.cost) : ""
                            Text("\(row.calls) wywołań · błędy \(row.failed) · \(row.input) in / \(row.output) out\(costStr)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Użycie")
        .onAppear { entries = model.usage(days: days) }
        .onChange(of: days) { entries = model.usage(days: days) }
    }

    @MainActor
    private func exportCSV() {
        let panel = NSSavePanel()
        panel.title = "Eksportuj historię użycia (CSV)"
        panel.nameFieldStringValue = "delegate-usage.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            let csv = UsageLog.csv(from: entries)
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    private func exportJSON() {
        let panel = NSSavePanel()
        panel.title = "Eksportuj historię użycia (JSON)"
        panel.nameFieldStringValue = "delegate-usage.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            if let json = try? UsageLog.json(from: entries) {
                try? json.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}
