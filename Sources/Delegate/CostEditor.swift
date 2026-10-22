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
        return cost.map(CostCategory.title) ?? "ustaw"
    }
}

extension CostCategory {
    static func title(_ category: String) -> String {
        switch category {
        case "free": "darmowy"
        case "cheap": "tani"
        case "paid": "płatny"
        case "varies": "zmienny"
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
            Picker("Rodzaj kosztu", selection: $mode) {
                Text("Kategoria").tag(Mode.category)
                Text("Kwota").tag(Mode.amount)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .category:
                Picker("Kategoria", selection: $setting.category) {
                    Text("— brak —").tag(String?.none)
                    ForEach(CostCategory.all, id: \.self) { c in
                        Text(CostCategory.title(c)).tag(String?.some(c))
                    }
                }
            case .amount:
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Text("Wejście")
                        TextField("0", value: $setting.priceIn, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                        Text("USD / 1M tok.").foregroundStyle(.secondary).font(.caption)
                    }
                    GridRow {
                        Text("Wyjście")
                        TextField("0", value: $setting.priceOut, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                        Text("USD / 1M tok.").foregroundStyle(.secondary).font(.caption)
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
