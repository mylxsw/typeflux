import Foundation

/// The split view owns its system glass/vibrancy; callers never add another glass panel.
public enum TypefluxSidebarMaterial: Equatable, Sendable {
    case system
    case opaque

    public static func resolve(style: InterfaceStyle, reduceTransparency: Bool, increasedContrast: Bool,
                               supportsLiquidGlass: Bool) -> Self {
        if reduceTransparency || increasedContrast {
            return .opaque
        }
        return supportsLiquidGlass && style == .classic ? .opaque : .system
    }
}
