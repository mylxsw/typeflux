@testable import Typeflux
import XCTest

final class StudioThemeTests: XCTestCase {
    // MARK: - Layout Constants

    func testLayoutConstantsArePositive() {
        XCTAssertGreaterThan(StudioTheme.Layout.sidebarWidth, 0)
        XCTAssertGreaterThan(StudioTheme.Layout.contentMaxWidth, 0)
        XCTAssertGreaterThan(StudioTheme.Layout.settingsWindowWidth, 0)
        XCTAssertGreaterThan(StudioTheme.Layout.overlayWidth, 0)
        XCTAssertGreaterThan(StudioTheme.Layout.contentInset, 0)
    }

    func testSidebarWidth() {
        XCTAssertEqual(StudioTheme.Layout.sidebarWidth, 210)
    }

    func testContentMaxWidth() {
        XCTAssertEqual(StudioTheme.Layout.contentMaxWidth, 1160)
    }

    func testSettingsWindowWidth() {
        XCTAssertEqual(StudioTheme.Layout.settingsWindowWidth, 1100)
    }

    func testSettingsWindowMinimumWidthKeepsOverviewOutOfCompactLayout() {
        let minimumContentWidth = StudioTheme.Layout.settingsWindowMinWidth
            - StudioTheme.Layout.sidebarWidth
            - StudioTheme.Layout.contentInset * 2

        XCTAssertEqual(StudioTheme.Layout.settingsWindowMinWidth, StudioTheme.Layout.settingsWindowWidth)
        XCTAssertGreaterThanOrEqual(
            minimumContentWidth,
            StudioOverviewPanelLayoutCalculator.compactBreakpoint
        )
    }

    func testOverlayWidth() {
        XCTAssertEqual(StudioTheme.Layout.overlayWidth, 320)
    }

    // MARK: - Top-level Convenience Properties

    func testTopLevelSidebarWidthMatchesLayout() {
        XCTAssertEqual(StudioTheme.sidebarWidth, StudioTheme.Layout.sidebarWidth)
    }

    func testTopLevelContentMaxWidthMatchesLayout() {
        XCTAssertEqual(StudioTheme.contentMaxWidth, StudioTheme.Layout.contentMaxWidth)
    }

    func testTopLevelContentInsetMatchesLayout() {
        XCTAssertEqual(StudioTheme.contentInset, StudioTheme.Layout.contentInset)
    }

    func testModelProviderIconPlateUsesWhiteBackground() {
        XCTAssertEqual(StudioTheme.modelProviderIconPlate, .white)
    }

    func testModelProviderFallbackSymbolUsesDarkForeground() {
        XCTAssertEqual(StudioTheme.modelProviderFallbackSymbol, .black.opacity(0.72))
    }

    // MARK: - Overview Layout

    func testOverviewLayoutUsesStackedArrangementForNarrowContent() {
        let layout = StudioOverviewPanelLayoutCalculator.layout(for: 700)

        XCTAssertEqual(layout.arrangement, .stacked)
        XCTAssertEqual(layout.activityWidth, 700)
        XCTAssertEqual(layout.metricsWidth, 700)
        XCTAssertGreaterThan(layout.height, StudioTheme.Layout.overviewPrimaryMinHeight)
    }

    func testOverviewLayoutUsesSideBySideArrangementForWideContent() {
        let layout = StudioOverviewPanelLayoutCalculator.layout(for: 1100)

        XCTAssertEqual(layout.arrangement, .sideBySide)
        XCTAssertEqual(layout.height, StudioTheme.Layout.overviewPrimaryMinHeight)
        XCTAssertLessThan(layout.metricsWidth, 1100)
        XCTAssertGreaterThan(layout.activityWidth, layout.metricsWidth)
    }
}
