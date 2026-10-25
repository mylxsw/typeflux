import Foundation

/// App-owned glass density. The midpoint preserves the tuned base surfaces;
/// moving right adds a tint above the native optics without replacing their blur.
struct LiquidGlassIntensity: Equatable {
    static let defaultValue = 0.9
    let value: Double

    init(_ value: Double = Self.defaultValue) {
        self.value = Self.normalized(value)
    }

    static func normalized(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : defaultValue
    }

    var extraTintOpacity: Double { max(0, value * 2 - 1) * 0.82 }

    func nativeFrostOpacity(_ base: Double) -> Double {
        base * min(1, value * 2)
    }

    func backdropOpacity(_ base: Double) -> Double {
        let frost = nativeFrostOpacity(base)
        return frost + (1 - frost) * extraTintOpacity
    }

    /// Legacy material keeps a minimum scrim so arbitrary desktop text cannot
    /// interfere with labels on systems without native Liquid Glass.
    func legacyFrostOpacity(_ base: Double) -> Double {
        let frost = base * (0.85 + min(1, value * 2) * 0.15)
        return frost + (1 - frost) * extraTintOpacity
    }
}
