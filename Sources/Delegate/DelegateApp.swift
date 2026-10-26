import SwiftUI

@main
struct DelegateApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.hasProviderIssues ? "exclamationmark.triangle" : "arrow.triangle.branch")
                if model.showUsageInMenuBar {
                    let stats = model.usageStats
                    Text(stats.costToday > 0 ? "\(stats.callsToday) · \(String(format: "$%.2f", stats.costToday))" : "\(stats.callsToday)")
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("Delegate", id: SettingsWindow.id) {
            SettingsView(model: model)
                .frame(minWidth: 820, minHeight: 540)
        }
        .defaultSize(width: 940, height: 640)
        .defaultLaunchBehavior(CommandLine.arguments.contains("--settings") ? .presented : .suppressed)
    }
}

enum SettingsWindow {
    static let id = "settings"
}
