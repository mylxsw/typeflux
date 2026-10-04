import Foundation

/// Keep the editor and primary actions available as the workspace shrinks.
/// The floating launcher retains its existing dimensions and controls.
struct AskComposerLayout: Equatable {
    var launcher: Bool
    var compact: Bool
    var width: CGFloat
    var availableHeight: CGFloat?
    var paletteOpen = false
    var supplementalHeight: CGFloat = 0

    /// Reserve one complete command row before the draft can consume the
    /// remaining viewport. This budget does not depend on the compact card's
    /// measured height, so changing density cannot oscillate during layout.
    var usesCompactMetrics: Bool {
        guard !launcher else { return false }
        let ordinaryCardMaximum: CGFloat = 148 + 14 + 4 + 48 + (supplementalHeight > 0 ? 160 : 0)
        let needsCommandRoom = paletteOpen && (availableHeight ?? .infinity) < ordinaryCardMaximum + 68 + 8
        return compact || needsCommandRoom
    }

    func paletteMaximumHeight(composerHeight: CGFloat) -> CGFloat? {
        availableHeight.map { max(68, $0 - max(composerHeight, maximumCardHeight) - 8) }
    }

    var maximumCardHeight: CGFloat {
        editorMaximumHeight + editorTopInset + editorBottomInset + footerHeight
            + (supplementalHeight > 0 ? supplementalMaximumHeight : 0)
    }

    var condensedFooter: Bool {
        !launcher && width < 600
    }

    var editorMaximumHeight: CGFloat {
        usesCompactMetrics ? 48 : 148
    }

    var supplementalMaximumHeight: CGFloat {
        usesCompactMetrics ? 40 : 160
    }

    var editorTopInset: CGFloat {
        usesCompactMetrics ? 6 : 14
    }

    var editorBottomInset: CGFloat {
        launcher || usesCompactMetrics ? 2 : 4
    }

    var footerHeight: CGFloat {
        launcher ? 54 : usesCompactMetrics ? 40 : 48
    }
}
