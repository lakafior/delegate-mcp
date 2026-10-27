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

    private var chartRange: ClosedRange<Date> {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let end = cal.date(byAdding: .day, value: 1, to: today) ?? today
        return start...end
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
                    Picker("Range", selection: $days) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)

                    Spacer()

                    Menu {
                        Button("Export CSV...") { exportCSV() }
                        Button("Export JSON...") { exportJSON() }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(entries.isEmpty)
                }

                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        StatTile(title: "Tokens delegated", value: totalTokens.formatted(),
                                 caption: "Didn't count against your assistant's limits")
                        StatTile(title: "Calls", value: "\(entries.count)",
                                 caption: "Errors: \(entries.filter { !$0.ok }.count)")
                    }
                    GridRow {
                        StatTile(title: "Cost", value: String(format: "$%.4f", totalCost),
                                 caption: "Paid models from providers")
                        StatTile(title: "Equivalent Sonnet API cost", value: String(format: "~$%.2f", totalSavings),
                                 caption: "What this would cost via the API, not the subscription")
                    }
                }
                if unpricedCount > 0 {
                    Label("\(unpricedCount) calls to models without a price aren't counted in cost or savings. Set amounts in the provider settings.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if entries.isEmpty {
                    ContentUnavailableView("No data", systemImage: "chart.bar", description: Text("Usage will appear after the first delegated tasks."))
                } else {
                    Chart(bars) { bar in
                        BarMark(x: .value("Day", bar.day, unit: .day), y: .value("Tokens", bar.tokens))
                            .foregroundStyle(by: .value("Model", bar.model))
                    }
                    // Stała oś na cały zakres: przy danych z jednego dnia Charts rozciągałby go na całą szerokość.
                    .chartXScale(domain: chartRange)
                    .chartXAxis { AxisMarks(values: .stride(by: .day, count: days > 7 ? 5 : 1)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    } }
                    .frame(height: 220)

                    ForEach(byModel) { row in
                        HStack {
                            Text(row.ref).font(.body.monospaced())
                            Spacer()
                            let costStr = row.priced ? String(format: " · $%.4f", row.cost) : ""
                            Text("\(row.calls) calls · errors \(row.failed) · \(row.input) in / \(row.output) out\(costStr)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Usage")
        .onAppear { entries = model.usage(days: days) }
        .onChange(of: days) { entries = model.usage(days: days) }
    }

    @MainActor
    private func exportCSV() {
        let panel = NSSavePanel()
        panel.title = "Export usage history (CSV)"
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
        panel.title = "Export usage history (JSON)"
        panel.nameFieldStringValue = "delegate-usage.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            if let json = try? UsageLog.json(from: entries) {
                try? json.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

/// Kafelek na treść: zwykłe tło, bez Liquid Glass (szkło jest dla warstwy kontrolek i nawigacji).
private struct StatTile: View {
    let title: String
    let value: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit())
            if let caption { Text(caption).font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }
}
