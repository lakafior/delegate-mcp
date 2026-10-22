import SwiftUI

struct RoutingView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                TextEditor(text: $model.config.routingGuidance)
                    .font(.body)
                    .frame(minHeight: 220)
            } header: {
                Text("Zasady routingu")
            } footer: {
                Text("Claude czyta ten tekst przez list_models. Opisz, co delegować, czego nie wysyłać i którego dostawcę kiedy wybierać.")
            }
            Section("Limity") {
                Stepper(value: $model.config.timeoutSeconds, in: 10...600, step: 10) {
                    LabeledContent("Limit czasu jednego wywołania", value: "\(Int(model.config.timeoutSeconds)) s")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Routing")
    }
}
