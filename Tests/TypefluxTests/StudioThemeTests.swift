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
        XCTAssertEqual(StudioTheme.Layout.sidebarWidth, 196)
    }

    func testContentMaxWidth() {
        XCTAssertEqual(StudioTheme.Layout.contentMaxWidth, 900)
    }

    func testSettingsWindowWidth() {
        XCTAssertEqual(StudioTheme.Layout.settingsWindowWidth, 1100)
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
}
