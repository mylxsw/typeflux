import AppKit
import SwiftUI

/// Resolve once per surface from SwiftUI's style, appearance and accessibility environment.
public struct TypefluxTokens {
    public let style: InterfaceStyle
    public let colorScheme: ColorScheme
    public let reduceTransparency: Bool
    public let increasedContrast: Bool
    public let material: GlassMaterial

    public init(style: InterfaceStyle, colorScheme: ColorScheme, reduceTransparency: Bool = false,
                increasedContrast: Bool = false, layer: GlassMaterial.Layer = .navigation,
                supportsLiquidGlass: Bool = GlassMaterial.systemSupportsLiquidGlass) {
        self.style = style
        self.colorScheme = colorScheme
        self.reduceTransparency = reduceTransparency
        self.increasedContrast = increasedContrast
        material = GlassMaterial.resolve(reduceTransparency: reduceTransparency, style: style,
                                         increasedContrast: increasedContrast, layer: layer,
                                         supportsLiquidGlass: supportsLiquidGlass)
    }

    public func radius(_ token: TypefluxRadius) -> CGFloat {
        token.value(for: style)
    }

    public func height(_ token: TypefluxControlHeight) -> CGFloat {
        token.value(for: style)
    }

    public func width(_ token: TypefluxControlWidth) -> CGFloat {
        token.value(for: style)
    }

    public func spacing(_ token: TypefluxSpacing) -> CGFloat {
        token.value(for: style)
    }

    /// Resolve semantic colours explicitly for previews/readouts as well as live windows.
    public func color(_ token: TypefluxColor) -> NSColor {
        let name: NSAppearance.Name = if increasedContrast {
            colorScheme == .dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua
        } else {
            colorScheme == .dark ? .darkAqua : .aqua
        }
        var result = token.nsColor
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            result = token.nsColor.usingColorSpace(.sRGB) ?? token.nsColor
        }
        return result
    }
}
