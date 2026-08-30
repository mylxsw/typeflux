@testable import Typeflux
import XCTest

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

    func testStrictEditApplyFallbackEnabledDefaultsToFalse() {
        XCTAssertFalse(store.strictEditApplyFallbackEnabled)
    }

    func testStrictEditApplyFallbackEnabledCanBeEnabledAndDisabled() {
        store.strictEditApplyFallbackEnabled = true
        XCTAssertTrue(store.strictEditApplyFallbackEnabled)

        store.strictEditApplyFallbackEnabled = false
        XCTAssertFalse(store.strictEditApplyFallbackEnabled)
    }

    func testStubbornPasteFallbackEnabledDefaultsToTrue() {
        XCTAssertTrue(store.stubbornPasteFallbackEnabled)
    }

    func testStubbornPasteFallbackEnabledCanBeEnabledAndDisabled() {
        store.stubbornPasteFallbackEnabled = true
        XCTAssertTrue(store.stubbornPasteFallbackEnabled)

        store.stubbornPasteFallbackEnabled = false
        XCTAssertFalse(store.stubbornPasteFallbackEnabled)
    }

    func testStubbornPasteFallbackEnabledPersistsExplicitFalse() {
        store.stubbornPasteFallbackEnabled = false

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.stubbornPasteFallbackEnabled)
    }

    func testLocalOptimizationEnabledDefaultsToFalse() {
        XCTAssertFalse(store.localOptimizationEnabled)
    }

    func testLocalOptimizationEnabledCanBeEnabledAndDisabled() {
        store.localOptimizationEnabled = true
        XCTAssertTrue(store.localOptimizationEnabled)

        store.localOptimizationEnabled = false
        XCTAssertFalse(store.localOptimizationEnabled)
    }

    func testInputContextOptimizationEnabledDefaultsToTrue() {
        XCTAssertTrue(store.inputContextOptimizationEnabled)
    }

    func testInputContextOptimizationEnabledCannotBeDisabled() {
        store.inputContextOptimizationEnabled = false
        XCTAssertTrue(store.inputContextOptimizationEnabled)
    }

    func testInputContextOptimizationEnabledOverridesPersistedFalse() {
        defaults.set(false, forKey: "inputContext.optimization.enabled")

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.inputContextOptimizationEnabled)
    }
}
