import Foundation

/// A display-safe domain. Reading a control never writes to the caller's binding.
struct TypefluxSliderDomain {
    let range: ClosedRange<Double>
    let step: Double?

    init(range: ClosedRange<Double>, step: Double?) {
        self.range = range.lowerBound.isFinite && range.upperBound.isFinite && range.lowerBound < range.upperBound
            ? range : 0...1
        self.step = step.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    func clamped(_ value: Double) -> Double {
        guard !value.isNaN else { return range.lowerBound }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}
