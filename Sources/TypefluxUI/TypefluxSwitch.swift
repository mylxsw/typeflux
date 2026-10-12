import SwiftUI

public struct TypefluxSwitch: View {
    @Binding private var isOn: Bool
    private let title: String
    private let labelsHidden: Bool

    public init(_ title: String, isOn: Binding<Bool>, labelsHidden: Bool = false) {
        self.title = title
        _isOn = isOn
        self.labelsHidden = labelsHidden
    }

    @ViewBuilder public var body: some View {
        if labelsHidden { toggle.labelsHidden() } else { toggle }
    }

    private var toggle: some View {
        Toggle(title, isOn: $isOn).toggleStyle(.switch).controlSize(.small).accessibilityLabel(Text(title))
    }
}
