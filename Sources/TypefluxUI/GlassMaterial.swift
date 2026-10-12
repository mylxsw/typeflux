import AppKit
import SwiftUI

public enum GlassMaterial: Equatable, Sendable {
    public enum Layer: Sendable { case navigation, content }

    /// macOS 26+: system Liquid Glass with its own refraction and highlights.
    case liquidGlass
    /// macOS 13–15: `NSVisualEffectView(.popover)` blending with the desktop behind the panel.
    case visualEffect
    /// Reduce Transparency or the classic style: the surface's opaque fill.
    case opaque

    public static func resolve(reduceTransparency: Bool, style: InterfaceStyle = .liquidGlass,
                               increasedContrast: Bool = false,
                               layer: Layer = .navigation,
                               supportsLiquidGlass: Bool = systemSupportsLiquidGlass) -> GlassMaterial {
        if reduceTransparency || increasedContrast || layer == .content || !style.usesGlass {
            return .opaque
        }
        return supportsLiquidGlass ? .liquidGlass : .visualEffect
    }

    /// True when this build and the running system both have the Liquid Glass API.
    /// An older compiler cannot reference it, so such builds always fall back.
    public static var systemSupportsLiquidGlass: Bool {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                return true
            }
        #endif
        return false
    }

    /// Translucent materials draw their own rim; only the opaque fill needs the
    /// card's border to separate it from the window behind.
    public var drawsOwnEdge: Bool {
        self != .opaque
    }
}
