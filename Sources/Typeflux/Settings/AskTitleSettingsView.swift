import SwiftUI

/// Agent settings retain the title behavior toggle; model roles live in model settings.
struct AskTitleSettingsView: View {
    let settings: SettingsStore
    @State private var enabled = true

    var body: some View {
        TFFormSection(title: L("ask.title.section")) {
            TFFormRow(title: L("ask.title.enabled"), detail: L("ask.title.enabled.subtitle"), icon: "pencil.line") {
                TFSwitch(title: L("ask.title.enabled"), isOn: $enabled)
            }
        }
        .onAppear { enabled = settings.askAutomaticTitles }
        .onChange(of: enabled) { settings.askAutomaticTitles = $0 }
    }
}
