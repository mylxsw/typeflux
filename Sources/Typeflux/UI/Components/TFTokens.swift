import SwiftUI

/// The three control heights every interactive component uses (see
/// `docs/design/settings-search-unification.md` §2.1). Controls in one row share a size.
enum TFControlSize: String, CaseIterable, Identifiable {
    /// 24pt: list rows, card header rows and inside menus.
    case small
    /// 30pt: the default for toolbars, forms, sheet footers and search fields.
    case regular
    /// 36pt: onboarding and the primary action of a full-page empty state.
    case large

    var id: String { rawValue }

    var height: CGFloat {
        switch self {
        case .small: 24
        case .regular: 30
        case .large: 36
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .small: 12
        case .regular: 13
        case .large: 14
        }
    }

    var fontWeight: Font.Weight { self == .large ? .semibold : .medium }

    var horizontalPadding: CGFloat {
        switch self {
        case .small: 10
        case .regular: 14
        case .large: 18
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .small: 11
        case .regular: 12
        case .large: 14
        }
    }

    var spacing: CGFloat {
        switch self {
        case .small: 5
        case .regular: 6
        case .large: 7
        }
    }

    /// Short labels such as "Cancel" keep a comfortable width; small row buttons hug their text.
    var minimumTextButtonWidth: CGFloat? { self == .small ? nil : 64 }

    /// The selected thumb of a segmented control sits 2pt inside its capsule track.
    var segmentItemHeight: CGFloat { height - TFMetrics.segmentInset * 2 }

    var segmentFontSize: CGFloat { self == .small ? 12 : 12.5 }

    var segmentHorizontalPadding: CGFloat { self == .small ? 9 : 12 }
}

/// Shared measurements. Containers nest concentrically: inner radius = outer radius − inset.
enum TFMetrics {
    static let borderWidth: CGFloat = 0.5
    static let focusRingWidth: CGFloat = 3.5
    static let disabledOpacity: Double = 0.45
    static let pressedScale: CGFloat = 0.97

    static let fieldCornerRadius: CGFloat = 8
    static let textAreaCornerRadius: CGFloat = 10
    static let cardCornerRadius: CGFloat = 12
    static let itemCornerRadius: CGFloat = 7
    static let sheetCornerRadius: CGFloat = 18
    static let iconTileCornerRadius: CGFloat = 7

    static let segmentInset: CGFloat = 2
    static let menuPadding: CGFloat = 5
    static let menuItemHeight: CGFloat = 26
    static let menuRichItemHeight: CGFloat = 44
    static let menuMaxWidth: CGFloat = 360
    static let menuMaxHeight: CGFloat = 360
    /// A menu with more options than this gets a search field.
    static let menuSearchThreshold = 12

    static let searchMinWidth: CGFloat = 200
    static let searchMaxWidth: CGFloat = 320

    static let formControlWidth: CGFloat = 220
    static let formControlWideWidth: CGFloat = 280
    static let formRowMinHeight: CGFloat = 52

    static let tabHeight: CGFloat = 32
    static let tabSpacing: CGFloat = 22
    static let tabIndicatorHeight: CGFloat = 2

    static let paneListWidth: CGFloat = 200
    /// Between a pane list and its pane.
    static let paneSpacing: CGFloat = 28
    static let paneRowHeight: CGFloat = 30
    /// Below this content width, pane lists fold into a picker and segmented filters into menus.
    static let compactContentWidth: CGFloat = 720

    static let rowHeight: CGFloat = 52
    static let singleLineRowHeight: CGFloat = 36
    static let compactRowHeight: CGFloat = 30
    static let rowHorizontalPadding: CGFloat = 12
    static let iconTileSize: CGFloat = 28
    static let tagHeight: CGFloat = 16

    static let toolbarSpacing: CGFloat = 8
    /// Between the sections (header + card) of a page.
    static let sectionSpacing: CGFloat = 24
}

/// Colors come from `StudioTheme`; this maps component roles onto those tokens.
enum TFColors {
    static let accent = StudioTheme.accent
    static let accentHover = StudioTheme.accentHover
    /// Selected rows and an active filter: a quiet accent fill.
    static let selection = StudioTheme.accentSoft
    static let control = StudioTheme.controlSurface
    static let raised = StudioTheme.selectionSurfaceRaised
    static let card = StudioTheme.cardSurface
    static let border = StudioTheme.border
    static let danger = StudioTheme.danger
    static let success = StudioTheme.success
    static let warning = StudioTheme.warning
    static let textPrimary = StudioTheme.textPrimary
    static let textSecondary = StudioTheme.textSecondary
    static let textTertiary = StudioTheme.textTertiary

    /// The hover and pressed overlays are the text color at low opacity, so they work on any fill.
    static let hoverOverlay = StudioTheme.textPrimary.opacity(0.06)
    static let pressedOverlay = StudioTheme.textPrimary.opacity(0.11)
    static let focusRing = StudioTheme.accent.opacity(0.30)
}

extension EnvironmentValues {
    /// The size a component uses when it is not given one. Set it once on a row or toolbar.
    @Entry var tfControlSize: TFControlSize = .regular
    /// True when the content area is narrower than `TFMetrics.compactContentWidth`.
    @Entry var tfCompactLayout: Bool = false
}

extension View {
    /// Sizes every component inside this view that does not choose its own size.
    func tfControlSize(_ size: TFControlSize) -> some View {
        environment(\.tfControlSize, size)
    }

    /// Marks the content as compact so adaptive components fold (segmented → menu, panes → picker).
    func tfCompactLayout(_ compact: Bool) -> some View {
        environment(\.tfCompactLayout, compact)
    }
}

/// Layout decisions that depend on the available width or option count.
enum TFLayout {
    static func isCompact(contentWidth: CGFloat) -> Bool {
        contentWidth < TFMetrics.compactContentWidth
    }

    enum FilterPresentation: Equatable {
        case segmented
        case menu
    }

    /// Filters with up to four options are a segmented control; more options, or a
    /// compact layout, fold into a filter menu.
    static func filterPresentation(optionCount: Int, compact: Bool) -> FilterPresentation {
        compact || optionCount > 4 ? .menu : .segmented
    }

    /// Menus get a search field once they hold more than `TFMetrics.menuSearchThreshold` options.
    static func menuNeedsSearch(optionCount: Int) -> Bool {
        optionCount > TFMetrics.menuSearchThreshold
    }
}
