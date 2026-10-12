import SwiftUI

/// Gallery/snapshot simulations can strengthen accessibility, never disable a system preference.
public struct TypefluxAccessibilityOptions: Equatable, Sendable {
    public let reduceTransparency: Bool
    public let increasedContrast: Bool

    public init(reduceTransparency: Bool = false, increasedContrast: Bool = false) {
        self.reduceTransparency = reduceTransparency
        self.increasedContrast = increasedContrast
    }
}

public extension EnvironmentValues {
    @Entry var typefluxAccessibilityOptions = TypefluxAccessibilityOptions()
}
