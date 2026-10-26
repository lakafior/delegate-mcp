import AppKit
import DelegateCore
import SwiftUI

struct DiagnosticsView: View {
    @Bindable var model: AppModel
    @State private var report: DiagnosticReport?
    @State private var isRunning = false
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Diagnostyka środowiska")
                            .font(.title2.bold())
                        Text("Weryfikacja konfiguracji TOML, kluczy API, łączności z dostawcami i integracji z Claude.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        if let report {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(report.terminalOutput(), forType: .string)
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                            } label: {
                                Label(copied ? "Skopiowano!" : "Kopiuj raport", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                        }

                        Button {
                            runDiagnostics()
                        } label: {
                            if isRunning {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.trailing, 2)
                            }
                            Label(isRunning ? "Sprawdzanie..." : "Uruchom testy", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRunning)
                    }
                }

                if let report {
                    summaryCard(report)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Elementy systemu")
                            .font(.headline)

                        VStack(spacing: 8) {
                            ForEach(report.checks) { check in
                                checkRow(check)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Dostawcy i modele")
                            .font(.headline)

                        VStack(spacing: 8) {
                            ForEach(report.providers) { p in
                                providerRow(p)
                            }
                        }
                    }
                } else if isRunning {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Trwa weryfikacja połączeń i konfiguracji...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(24)
        }
        .navigationTitle("Diagnostyka")
        .task {
            if report == nil {
                runDiagnostics()
            }
        }
    }

    private func summaryCard(_ rep: DiagnosticReport) -> some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 16) {
                Image(systemName: rep.allOk ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(rep.allOk ? .green : .orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text(rep.allOk ? "Wszystkie komponenty działają prawidłowo" : "Wykryto kwestie wymagające uwagi")
                        .font(.headline)
                    Text("Ostatni test: \(rep.timestamp.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                let okCount = rep.checks.filter { $0.severity == .ok }.count + rep.providers.filter { $0.severity == .ok }.count
                let issues = rep.checks.filter { $0.severity != .ok }.count + rep.providers.filter { $0.severity != .ok }.count

                HStack(spacing: 12) {
                    VStack(alignment: .trailing) {
                        Text("\(okCount)").font(.title3.bold()).foregroundStyle(.green)
                        Text("Zaliczone").font(.caption2).foregroundStyle(.secondary)
                    }
                    if issues > 0 {
                        Divider().frame(height: 24)
                        VStack(alignment: .trailing) {
                            Text("\(issues)").font(.title3.bold()).foregroundStyle(.orange)
                            Text("Uwagi").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private func checkRow(_ check: DiagnosticCheck) -> some View {
        HStack(alignment: .center, spacing: 14) {
            statusIcon(check.severity)

            VStack(alignment: .leading, spacing: 2) {
                Text(check.name)
                    .font(.body.weight(.medium))
                Text(check.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let detail = check.detail {
                    Text(detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if check.severity != .ok && check.fixable {
                Button("Napraw") {
                    fixCheck(check)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private func providerRow(_ p: ProviderDiagnostic) -> some View {
        HStack(alignment: .center, spacing: 14) {
            statusIcon(p.severity)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(p.providerID)
                        .font(.body.weight(.medium).monospaced())
                    Text("(\(p.kind))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let err = p.error {
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.red)
                } else {
                    Text(p.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let ms = p.responseTimeMs {
                Text("\(ms) ms")
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: .capsule)
            }

            if let count = p.modelsCount {
                Text("\(count) modeli")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private func statusIcon(_ severity: DiagnosticSeverity) -> some View {
        switch severity {
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.title3)
        }
    }

    private func fixCheck(_ check: DiagnosticCheck) {
        if check.name.contains("Claude Desktop") {
            model.installDesktop(true)
        } else if check.name.contains("CLAUDE.md") {
            model.installInstructions(true)
        }
        runDiagnostics()
    }

    private func runDiagnostics() {
        guard !isRunning else { return }
        isRunning = true
        Task {
            let doc = DelegateDoctor(home: model.home)
            let result = await doc.diagnose()
            await MainActor.run {
                self.report = result
                self.isRunning = false
            }
        }
    }
}
