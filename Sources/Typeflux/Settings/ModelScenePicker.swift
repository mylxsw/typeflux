import SwiftUI

/// Scene eligibility and persistence stay owned by the model library.
struct ModelScenePicker: View {
    @ObservedObject var library: AskModelLibrary
    @Binding var reference: String
    let scenario: String
    let title: String
    @Environment(\.interfaceStyle) private var style
    @ObservedObject private var auth = AuthState.shared

    var body: some View {
        TypefluxSearchablePopup(title, selectedTitle: library.name(for: reference, scenario: scenario),
                                searchPrompt: L("models.search"),
                                options: library.selectableProviders(
                                    loggedIn: auth.isLoggedIn,
                                    hasImage: false,
                                    scenario: scenario
                                )
                                .flatMap { provider in
                                    provider.models.map { (
                                        label: provider.name + " · " + $0.name,
                                        value: $0.reference
                                    ) }
                                }, selection: Binding(
                                    get: { library.presentationReference(for: reference, scenario: scenario) },
                                    set: { reference = $0 }
                                ))
                                .frame(width: 240, height: TypefluxControlHeight.popup.value(for: style))
                                .help(L("ask.models.conversationOnly"))
    }
}
