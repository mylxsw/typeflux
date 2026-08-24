@testable import Typeflux
import XCTest

final class OnboardingProviderStyleTests: XCTestCase {
    func testListColumnWidthIsSlightlyNarrowerThanPreviousLayout() {
        XCTAssertEqual(OnboardingProviderStyle.listColumnWidth, 408)
        XCTAssertLessThan(OnboardingProviderStyle.listColumnWidth, 430)
    }
}
