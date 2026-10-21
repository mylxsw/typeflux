import SwiftUI

/// Agent → Overview: how a temporary conversation ends.
struct AskTemporarySettingsView: View {
    let settings: SettingsStore
    @State private var confirmLeaving = true

    var body: some View {
        TFFormRow(title: L("ask.temporary.settings.confirm"), detail: L("ask.temporary.settings.confirm.subtitle"),
                  icon: AskStorageKind.temporary.symbol) {
            TFSwitch(title: L("ask.temporary.settings.confirm"), isOn: $confirmLeaving)
                .accessibilityIdentifier("agent.settings.confirmLeavingTemporary")
        }
        .onAppear { confirmLeaving = settings.askConfirmLeavingTemporary }
        .onChange(of: confirmLeaving) { settings.askConfirmLeavingTemporary = $0 }
    }
}
