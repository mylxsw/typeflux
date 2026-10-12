import SwiftUI

public extension EnvironmentValues {
    @Entry var interfaceStyle: InterfaceStyle = .liquidGlass

    @Entry var liquidGlassIntensity: LiquidGlassIntensity = .init()

    // Used by bitmap snapshots, which cannot capture the window server compositor.
    @Entry var glassMaterialOverride: GlassMaterial?
}
