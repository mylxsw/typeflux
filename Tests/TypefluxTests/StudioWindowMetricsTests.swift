@testable import Typeflux
import XCTest
import Foundation

final class StudioWindowMetricsTests: XCTestCase {
    // MARK: - Layout Constants

    func testLayoutConstantsArePositive() {
        XCTAssertGreaterThan(StudioWindowMetrics.sidebarWidth, 0)
        XCTAssertGreaterThan(StudioWindowMetrics.contentMaxWidth, 0)
        XCTAssertGreaterThan(StudioWindowMetrics.settingsWindowWidth, 0)
        XCTAssertGreaterThan(StudioWindowMetrics.overlayWidth, 0)
        XCTAssertGreaterThan(StudioWindowMetrics.contentInset, 0)
    }

    func testSidebarWidth() {
        XCTAssertEqual(StudioWindowMetrics.sidebarWidth, AskMetrics.sidebarWidth)
    }

    func testContentMaxWidth() {
        XCTAssertEqual(StudioWindowMetrics.contentMaxWidth, 1160)
    }

    func testSettingsWindowWidth() {
        XCTAssertEqual(StudioWindowMetrics.settingsWindowWidth, 1100)
    }

    func testSettingsWindowNavigationYieldsToNarrowContent() {
        for width: CGFloat in [720, 900, 1039, 1040, 1100, 1440] {
            let layout = StudioShellLayout(width: width)
            XCTAssertEqual(layout.sidebarWidth, width >= 1040 ? 220 : 0)
            XCTAssertGreaterThanOrEqual(layout.contentWidth, 672)
            XCTAssertLessThanOrEqual(layout.contentWidth + layout.sidebarWidth + layout.horizontalInset * 2, width)
        }
        XCTAssertLessThan(StudioWindowMetrics.settingsWindowMinWidth, StudioWindowMetrics.settingsWindowWidth)
        XCTAssertTrue(SettingsPaneMetrics.isCompact(contentWidth:
            StudioShellLayout(width: StudioWindowMetrics.settingsWindowMinWidth).contentWidth))
    }

    func testOverlayWidth() {
        XCTAssertEqual(StudioWindowMetrics.overlayWidth, 320)
    }

    func testModelProviderIconPlateUsesWhiteBackground() {
        XCTAssertEqual(LegacyStudioPalette.modelProviderIconPlate, .white)
    }

    func testModelProviderFallbackSymbolUsesDarkForeground() {
        XCTAssertEqual(LegacyStudioPalette.modelProviderFallbackSymbol, .black.opacity(0.72))
    }
}
