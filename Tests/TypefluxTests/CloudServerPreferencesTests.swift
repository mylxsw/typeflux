@testable import Typeflux
import XCTest

final class CloudServerPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "CloudServerPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsToAutomaticSelection() {
        let preferences = CloudServerPreferences(defaults: defaults)

        XCTAssertEqual(preferences.preferredAPIServer, CloudServerPreferences.automaticValue)
        XCTAssertEqual(preferences.preferredASRServer, CloudServerPreferences.automaticValue)
        XCTAssertNil(preferences.preferredAPIURL)
        XCTAssertNil(preferences.preferredASRURL)
    }

    func testPersistsNormalizedServerSelections() {
        let preferences = CloudServerPreferences(defaults: defaults)

        preferences.preferredAPIServer = " HTTPS://api.example.com/ "
        preferences.preferredASRServer = "https://asr.example.com?source=test"

        XCTAssertEqual(preferences.preferredAPIServer, "https://api.example.com/")
        XCTAssertEqual(preferences.preferredASRServer, "https://asr.example.com")
    }

    func testSelectingAutomaticRemovesPersistedPreference() {
        let preferences = CloudServerPreferences(defaults: defaults)
        preferences.preferredAPIServer = "https://api.example.com"

        preferences.preferredAPIServer = CloudServerPreferences.automaticValue

        XCTAssertEqual(preferences.preferredAPIServer, CloudServerPreferences.automaticValue)
        XCTAssertNil(preferences.preferredAPIURL)
    }
}
