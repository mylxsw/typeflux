import SwiftUI

/// Search stays visible beside the list; focusing it ends any shortcut recording.
struct HotkeySettingsSearch: View {
    @Binding var text: String
    var onFocus: () -> Void = {}

    var body: some View {
        SettingsSearchBox(placeholder: L("hotkeys.search"), text: $text, width: nil, onFocus: onFocus,
                          fieldIdentifier: "hotkeys.search")
    }
}
