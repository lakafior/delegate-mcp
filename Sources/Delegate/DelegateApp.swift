import SwiftUI

@main
struct DelegateApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(systemName: "arrow.triangle.branch")
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
