import Foundation
import TypefluxUI

/// Account for the split Spotlight chrome without changing legacy composer metrics.
enum AskLauncherSpotlightLayout {
    static func headerHeight(editor: CGFloat, style: InterfaceStyle) -> CGFloat {
        max(TypefluxControlHeight.spotlightInput.value(for: style),
            editor + TypefluxSpacing.small.value(for: style) * 2)
    }

    static func chromeAdjustment(editor: CGFloat, style: InterfaceStyle, collapsed: Bool) -> CGFloat {
        headerHeight(editor: editor, style: style) - AskMetrics.launcherHeaderHeight(editor: editor)
            + (style.usesGlass && !collapsed ? TypefluxSpacing.regular.value(for: style) : 0)
    }
}
