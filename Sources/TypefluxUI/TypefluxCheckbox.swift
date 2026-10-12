import SwiftUI

public struct TypefluxCheckbox: View {
    @Binding private var isOn: Bool
    private let title: String

    public init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    public var body: some View { Toggle(title, isOn: $isOn).toggleStyle(.checkbox) }
}
