import SwiftUI

/// Capture controls live in independent AppKit hosting views. Each root must
/// observe the app settings explicitly instead of inheriting SwiftUI defaults.
struct ScreenshotAppearanceRoot: ViewModifier {
    @StateObject private var observer: InterfaceStyleObserver

    init(settings: SettingsStore) {
        _observer = StateObject(wrappedValue: InterfaceStyleObserver(settings: settings))
    }

    func body(content: Content) -> some View {
        content.interfaceStyle(following: observer)
    }
}

/// Capture toolbars share the floating panels' neutral tint. Classic keeps
/// each control's existing opaque palette without introducing another material.
struct ScreenshotSurface: ViewModifier {
    @Environment(\.interfaceStyle) private var style
    let corner: CGFloat
    var elevation: AskElevation? = .popover
    var placement: AskGlassPlacement = .inWindow
    var classicFill: Color = AskTheme.glassFill

    func body(content: Content) -> some View {
        content.askInWindowGlass(corner: corner,
                                 opaqueFill: style == .classic ? classicFill : AskTheme.launcherSurface,
                                 elevation: elevation, placement: placement)
    }
}

extension View {
    func screenshotSurface(corner: CGFloat, elevation: AskElevation? = .popover,
                           placement: AskGlassPlacement = .inWindow,
                           classicFill: Color = AskTheme.glassFill) -> some View {
        modifier(ScreenshotSurface(corner: corner, elevation: elevation,
                                   placement: placement, classicFill: classicFill))
    }

    func screenshotAppearance(settings: SettingsStore = SettingsStore()) -> some View {
        modifier(ScreenshotAppearanceRoot(settings: settings))
    }
}
