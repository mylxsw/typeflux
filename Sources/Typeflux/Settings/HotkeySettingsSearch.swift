import SwiftUI

/// A title-bar search that expands from its icon and returns to it on Escape.
struct HotkeySettingsSearch: View {
    @Binding var text: String
    var width: CGFloat = 240
    var onOpen: () -> Void = {}
    @State private var expanded = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if expanded {
                    close()
                } else {
                    onOpen()
                    expanded = true
                    focused = true
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("hotkeys.search"))
            .accessibilityLabel(L("hotkeys.search"))
            .accessibilityIdentifier("hotkeys.search.toggle")

            if expanded {
                TextField(L("hotkeys.search"), text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsControlMetrics.fontSize))
                    .focused($focused)
                    .accessibilityLabel(L("hotkeys.search"))
                    .accessibilityIdentifier("hotkeys.search")
                    .onExitCommand(perform: close)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("hotkeys.search.close"))
                .accessibilityIdentifier("hotkeys.search.close")
            }
        }
        .foregroundStyle(StudioTheme.textSecondary)
        .frame(width: expanded ? width : 30, height: SettingsControlMetrics.height)
        .modifier(SettingsControlChrome(focused: focused))
        .clipped()
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: expanded)
    }

    private func close() {
        text = ""
        focused = false
        expanded = false
    }
}
