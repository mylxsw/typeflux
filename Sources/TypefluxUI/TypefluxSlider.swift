import SwiftUI

public struct TypefluxSlider: View {
    @Binding private var value: Double
    private let title: String
    private let domain: TypefluxSliderDomain
    private let onEditingChanged: (Bool) -> Void

    public init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double> = 0...1,
                step: Double? = nil, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title
        _value = value
        domain = TypefluxSliderDomain(range: range, step: step)
        self.onEditingChanged = onEditingChanged
    }

    @ViewBuilder public var body: some View {
        if let step = domain.step {
            Slider(value: displayValue, in: domain.range, step: step, onEditingChanged: onEditingChanged) {
                Text(title)
            }
        } else {
            Slider(value: displayValue, in: domain.range, onEditingChanged: onEditingChanged) {
                Text(title)
            }
        }
    }

    private var displayValue: Binding<Double> {
        Binding(get: { domain.clamped(value) }, set: { value = domain.clamped($0) })
    }
}
