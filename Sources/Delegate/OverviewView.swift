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
                Section("Dostawcy") {
                    ForEach(report.providers) { providerRow($0) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Przegląd")
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
        .task {
            model.refreshUsage()
            if model.diagnostics == nil { model.runDiagnostics() }
        }
    }

    // MARK: podsumowanie

    private var summary: some View {
        let severities = (model.diagnostics?.checks.map(\.severity) ?? []) + (model.diagnostics?.providers.map(\.severity) ?? [])
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
                Text(model.diagnostics == nil ? "Sprawdzam serwer, klucze i połączenia…"
                     : errors > 0 ? "Są błędy do naprawienia"
                     : warnings > 0 ? "Działa, są uwagi" : "Wszystko działa")
                    .font(.headline)
                Text("Claude oddelegował \(stats.callsWeek) zadań w 7 dni, dziś \(stats.callsToday).")
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
                    Text(model.instructionsOutdated ? "starsza wersja" : (model.instructionsInstalled ? "aktualne" : "brak"))
                        .foregroundStyle(model.instructionsOutdated ? .orange : .secondary)
                    if model.instructionsInstalled {
                        if model.instructionsOutdated { Button("Zaktualizuj") { model.installInstructions(true) } }
                        Button("Usuń") { model.installInstructions(false) }
                    } else {
                        Button("Dodaj") { model.installInstructions(true) }
                    }
                }
            } label: {
                Text("Przypomnienie w ~/.claude/CLAUDE.md")
                Text("Opcjonalne: serwer sam podaje Claude'owi instrukcje.")
            }
            LabeledContent {
                Button("Zezwól") { model.apply(.authorizeKeys) }
                    .disabled(!model.helperExists)
            } label: {
                Text("Dostęp serwera do kluczy")
                Text(keyAccessText)
            }
            if let message = model.integrationMessage {
                Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            if !model.helperExists {
                Label("Nie znaleziono delegate-mcp obok aplikacji. Zbuduj całość skryptem scripts/build-app.sh.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
        } header: {
            Text("Claude")
        } footer: {
            Text("Wystarczy podłączyć Desktop albo Code. Po zmianach dostawców zrestartuj Claude'a, żeby wczytał nowe instrukcje.")
        }
    }

    private var keyAccessText: String {
        guard let check = model.diagnostics?.checks.first(where: { $0.fix == .authorizeKeys || $0.name == "Dostęp serwera do kluczy" })
        else { return "Gdy macOS pyta o hasło przy użyciu kluczy przez serwer." }
        return check.message
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
                    Button("Odłącz", action: remove)
                case .notInstalled:
                    Button("Podłącz", action: install).disabled(!enabled)
                case .stale:
                    Button("Napraw", action: install).disabled(!enabled)
                }
            }
        }
    }
}

extension DiagnosticFix {
    var title: String {
        switch self {
        case .installDesktop, .installCode: "Podłącz"
        case .updateInstructions: "Dodaj / zaktualizuj"
        case .authorizeKeys: "Zezwól"
        }
    }
}
