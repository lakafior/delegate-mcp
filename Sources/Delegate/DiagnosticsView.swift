import AppKit
import DelegateCore
import SwiftUI

struct DiagnosticsView: View {
    @Bindable var model: AppModel
    @State private var copied = false

    var body: some View {
        Form {
            if let report = model.diagnostics {
                Section { summary(report) }
                Section("System i Claude") {
                    ForEach(report.checks) { checkRow($0) }
                }
                Section("Dostawcy") {
                    ForEach(report.providers) { providerRow($0) }
                }
            } else {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Sprawdzam serwer, klucze i połączenia…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Diagnostyka")
        .toolbar {
            ToolbarItemGroup {
                if let report = model.diagnostics {
                    Button(copied ? "Skopiowano" : "Kopiuj raport", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.terminalOutput(), forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    }
                }
                Button("Sprawdź ponownie", systemImage: "arrow.clockwise") { model.runDiagnostics() }
                    .disabled(model.diagnosing)
            }
        }
        .task { if model.diagnostics == nil { model.runDiagnostics() } }
    }

    private func summary(_ report: DiagnosticReport) -> some View {
        let all = report.checks.map(\.severity) + report.providers.map(\.severity)
        let errors = all.filter { $0 == .error }.count
        let warnings = all.filter { $0 == .warning }.count
        return HStack(spacing: 12) {
            Image(systemName: errors > 0 ? "xmark.octagon.fill" : (warnings > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"))
                .font(.title)
                .foregroundStyle(errors > 0 ? .red : (warnings > 0 ? .orange : .green))
            VStack(alignment: .leading, spacing: 2) {
                Text(errors > 0 ? "Są błędy do naprawienia" : (warnings > 0 ? "Działa, są uwagi" : "Wszystko działa"))
                    .font(.headline)
                Text("Błędy: \(errors) · uwagi: \(warnings) · sprawdzono \(report.timestamp.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.diagnosing { ProgressView().controlSize(.small) }
        }
    }

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

extension DiagnosticFix {
    var title: String {
        switch self {
        case .installDesktop: "Podłącz"
        case .installCode: "Podłącz"
        case .updateInstructions: "Dodaj / zaktualizuj"
        case .authorizeKeys: "Zezwól"
        }
    }
}
