import SwiftUI

/// The workspace chooser uses the system menu's metrics, selection, focus and keyboard routing.
/// Rich composer cards remain available to the floating launcher's nonactivating panel.
struct AskNativeModelMenu<Label: View>: View {
    @ObservedObject var library: AskModelLibrary
    @Binding var reference: String
    var effort: Binding<AskReasoningEffort>?
    var scenario: String
    var hasImage: Bool
    var loggedIn: Bool
    var showsDefaultAction: Bool
    var offersSignIn: Bool
    var onManage: (() -> Void)?
    @ViewBuilder var label: () -> Label

    private var selectedReference: String { library.presentationReference(for: reference, scenario: scenario) }

    var body: some View {
        TypefluxMenu(borderless: true) {
            let providers = library.selectableProviders(loggedIn: loggedIn, hasImage: false, scenario: scenario)
            if providers.isEmpty {
                Text(L("models.noAvailable"))
            }
            ForEach(providers) { provider in
                Section(provider.name) {
                    ForEach(provider.models) { model in
                        modelChoice(model, provider: provider)
                    }
                }
            }
            if let effort {
                let levels = AskReasoningEffort.levels(for: library.registry.resolve(selectedReference)?.1)
                if !levels.isEmpty {
                    Divider()
                    Picker(L("ask.reasoning.title"), selection: effort) {
                        Text(AskReasoningEffort.providerDefault.label).tag(AskReasoningEffort.providerDefault)
                        ForEach(levels, id: \.self) { level in Text(level.label).tag(level) }
                    }
                }
            }
            if showsDefaultAction || onManage != nil || offersSignIn { Divider() }
            if showsDefaultAction {
                Button(L("ask.models.makeDefault")) { library.defaultReference = reference }
                    .disabled(library.selectionExplanation(for: reference, hasImage: hasImage,
                                                           loggedIn: loggedIn, scenario: scenario) != nil)
            }
            if let onManage {
                Button(action: onManage) { SwiftUI.Label(L("ask.models.manage"), systemImage: "gearshape") }
            }
            if offersSignIn {
                Button { LoginWindowController.shared.show() } label: {
                    SwiftUI.Label(L("ask.cloudPromo.signIn"), systemImage: "cloud")
                }
            }
        } label: { label() }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func modelChoice(_ model: RegisteredModel, provider: RegisteredProvider) -> some View {
        let reason = library.selectionReason(model, provider: provider, hasImage: hasImage,
                                             loggedIn: loggedIn, scenario: scenario)
        let symbol: String
        if selectedReference == model.reference {
            symbol = "checkmark"
        } else {
            symbol = provider.isCloud ? "cloud" : "cpu"
        }
        return Button { reference = model.reference } label: {
            SwiftUI.Label(model.displayName, systemImage: symbol)
        }
        .disabled(reason != nil)
        .help(reason ?? model.displayName)
        .accessibilityHint(reason ?? "")
        .accessibilityIdentifier("ask.model.choice." + model.reference)
    }
}
