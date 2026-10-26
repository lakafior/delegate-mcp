import DelegateCore
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Delegate", systemImage: "arrow.triangle.branch")
                    .font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("dziś: \(model.callsToday)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.costToday > 0 {
                        Text(String(format: "$%.4f", model.costToday))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if model.config.providers.isEmpty {
                Text("Brak dostawców. Dodaj ich w ustawieniach.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                GlassEffectContainer(spacing: 8) {
                    VStack(spacing: 8) {
                        ForEach($model.config.providers) { $provider in
                            ProviderRow(
                                provider: $provider,
                                status: model.status(of: provider),
                                isTesting: model.testing.contains(provider.id),
                                testResult: model.testResults[provider.id]
                            )
                        }
                    }
                }
            }

            HStack {
                Button {
                    model.testAll()
                } label: {
                    if model.isTestingAny {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("Testowanie…")
                        }
                    } else {
                        Label("Testuj połączenia", systemImage: "bolt.badge.checkmark")
                    }
                }
                .buttonStyle(.glass)
                .disabled(model.isTestingAny || model.config.providers.isEmpty)

                Spacer()

                Button("Ustawienia…", systemImage: "gearshape") {
                    openWindow(id: SettingsWindow.id)
                    NSApp.activate()
                }
                .buttonStyle(.glass)

                Button("Zakończ") { NSApp.terminate(nil) }
                    .buttonStyle(.glass)
            }
        }
        .padding(14)
        .frame(width: 330)
        .onAppear {
            model.reloadIfChangedOnDisk()
            model.refresh()
        }
        .onChange(of: model.config) { model.configChanged() }
    }
}

private struct ProviderRow: View {
    @Binding var provider: ProviderConfig
    let status: ProviderStatus
    let isTesting: Bool
    let testResult: Result<String, DelegateError>?

    var body: some View {
        HStack(spacing: 10) {
            if isTesting {
                ProgressView().controlSize(.small)
                    .frame(width: 9, height: 9)
            } else {
                StatusDot(status: status)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(provider.id).font(.body)
                    if let result = testResult {
                        switch result {
                        case .success:
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        case .failure:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                }
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("Włączony", isOn: $provider.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}
