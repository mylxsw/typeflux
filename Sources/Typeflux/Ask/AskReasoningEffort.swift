import SwiftUI

enum AskReasoningEffort: String, CaseIterable {
    case providerDefault = ""
    case low, medium, high

    var label: String {
        L("ask.reasoning." + (self == .providerDefault ? "default" : rawValue))
    }

    func requestValue(for model: RegisteredModel?) -> String? {
        guard model?.reference.hasPrefix("cloud:") == true, model?.reasoning == true,
              self != .providerDefault else { return nil }
        return rawValue
    }
}

struct AskReasoningMenu: View {
    @ObservedObject var library: AskModelLibrary
    var reference: String
    @Binding var effort: AskReasoningEffort
    var disabled = false

    var body: some View {
        if reference.hasPrefix("cloud:"), library.registry.resolve(reference)?.1.reasoning == true {
            Menu {
                Picker(L("ask.reasoning.title"), selection: $effort) {
                    ForEach(AskReasoningEffort.allCases, id: \.self) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
            } label: {
                Label(effort.label, systemImage: "brain")
                    .font(.system(size: 12))
            }
            .fixedSize()
            .disabled(disabled)
            .help(L("ask.reasoning.help"))
            .accessibilityLabel(L("ask.reasoning.title"))
        }
    }
}
