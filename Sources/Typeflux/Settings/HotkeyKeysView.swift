import SwiftUI

/// Native key hints for a shortcut, an unset binding, or the recording prompt.
struct HotkeyKeysView: View {
    let binding: HotkeyBinding?
    var isRecording = false

    var body: some View {
        HStack {
            if isRecording {
                TypefluxKeyHint(L("hotkeys.recording"), accessibilityLabel: L("hotkeys.recording"))
            } else if let binding {
                ForEach(Array(HotkeyFormat.components(binding).enumerated()), id: \.offset) { _, key in
                    TypefluxKeyHint(key, accessibilityLabel: key)
                }
                if let count = HotkeyFormat.pressCount(binding) {
                    Text("×\(count)").font(.subheadline).foregroundStyle(TypefluxColor.secondaryLabel.color)
                }
            } else {
                TypefluxKeyHint(L("settings.shortcuts.none"), accessibilityLabel: L("settings.shortcuts.none"))
            }
        }
    }
}
