import XCTest
@testable import Typeflux

final class SettingsStoreFeatureFlagTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: SettingsStore!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsStoreFeatureFlagTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        suiteName = nil
        super.tearDown()
    }

    func testStrictEditApplyFallbackEnabledDefaultsToTrue() {
        XCTAssertTrue(store.strictEditApplyFallbackEnabled)
    }

    func testStrictEditApplyFallbackEnabledCanBeEnabledAndDisabled() {
        store.strictEditApplyFallbackEnabled = true
        XCTAssertTrue(store.strictEditApplyFallbackEnabled)

        store.strictEditApplyFallbackEnabled = false
        XCTAssertFalse(store.strictEditApplyFallbackEnabled)
    }
}
