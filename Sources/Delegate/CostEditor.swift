import DelegateCore
import SwiftUI

/// Koszt modelu: kategoria albo kwoty (USD za 1M tokenów). Tryby się wykluczają.
struct CostSetting: Equatable {
    var category: String?
    var priceIn: Double?
    var priceOut: Double?

    var isAmount: Bool { priceIn != nil || priceOut != nil }
}

extension ModelConfig {
    var costSetting: CostSetting {
        get { CostSetting(category: cost, priceIn: priceIn, priceOut: priceOut) }
        set { cost = newValue.category; priceIn = newValue.priceIn; priceOut = newValue.priceOut }
    }

    /// Krótki tekst na przycisk w wierszu.
    var shortCost: String {
        if priceIn != nil || priceOut != nil {
            return "$\(ModelConfig.money(priceIn)) / $\(ModelConfig.money(priceOut))"
        }
        return cost.map(CostCategory.title) ?? "set"
    }
}

extension CostCategory {
    static func title(_ category: String) -> String {
        switch category {
        case "free": "free"
        case "cheap": "cheap"
        case "paid": "paid"
        case "varies": "varies"
        default: category
        }
    }
}

struct CostEditor: View {
    @Binding var setting: CostSetting
    @State private var mode: Mode

    enum Mode: Hashable { case category, amount }

    init(setting: Binding<CostSetting>) {
        _setting = setting
        _mode = State(initialValue: setting.wrappedValue.isAmount ? .amount : .category)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Cost type", selection: $mode) {
                Text("Category").tag(Mode.category)
                Text("Amount").tag(Mode.amount)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .category:
                Picker("Category", selection: $setting.category) {
                    Text("— none —").tag(String?.none)
                    ForEach(CostCategory.all, id: \.self) { c in
                        Text(CostCategory.title(c)).tag(String?.some(c))
                    }
                }
            case .amount:
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Text("Input")
                        TextField("0", value: $setting.priceIn, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                        Text("USD / 1M tokens").foregroundStyle(.secondary).font(.caption)
                    }
                    GridRow {
                        Text("Output")
                        TextField("0", value: $setting.priceOut, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                        Text("USD / 1M tokens").foregroundStyle(.secondary).font(.caption)
                    }
                }
            }
        }
        .onChange(of: mode) {
            switch mode {
            case .category:
                setting.priceIn = nil
                setting.priceOut = nil
                if setting.category == nil { setting.category = "cheap" }
            case .amount:
                setting.category = nil
                setting.priceIn = setting.priceIn ?? 0
                setting.priceOut = setting.priceOut ?? 0
            }
        }
    }
}
