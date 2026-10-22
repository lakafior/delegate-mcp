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
                Text("dziś: \(model.callsToday)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.config.providers.isEmpty {
                Text("Brak dostawców. Dodaj ich w ustawieniach.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                GlassEffectContainer(spacing: 8) {
                    VStack(spacing: 8) {
                        ForEach($model.config.providers) { $provider in
                            ProviderRow(provider: $provider, status: model.status(of: provider))
                        }
                    }
                }
            }

            HStack {
                Button("Ustawienia…", systemImage: "gearshape") {
                    openWindow(id: SettingsWindow.id)
                    NSApp.activate()
                }
                .buttonStyle(.glass)
                Spacer()
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

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: status)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.id).font(.body)
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
