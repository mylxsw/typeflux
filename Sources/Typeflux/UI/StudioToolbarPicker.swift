import SwiftUI

/// Keep one page-specific segment in the toolbar, folding to a native picker on narrow windows.
struct StudioToolbarPicker<Selection: Hashable, Options: View>: View {
    @Environment(\.studioWindowWidth) private var windowWidth
    private let title: String
    @Binding private var selection: Selection
    private let options: Options

    init(_ title: String, selection: Binding<Selection>, @ViewBuilder options: () -> Options) {
        self.title = title
        _selection = selection
        self.options = options()
    }

    var body: some View {
        Group {
            if (windowWidth ?? 1100) < 1040 {
                Picker(title, selection: $selection) { options }
                    .pickerStyle(.menu).labelsHidden()
            } else {
                TypefluxSegmentedControl(title, selection: $selection) { options }
            }
        }
        .fixedSize()
        .accessibilityLabel(title)
    }
}
