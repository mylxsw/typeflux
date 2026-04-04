import XCTest
@testable import Typeflux

final class SettingsStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: SettingsStore!

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - STT Provider

    func testDefaultSTTProvider() {
        XCTAssertEqual(store.sttProvider, .whisperAPI)
    }

    func testSetAndGetSTTProvider() {
        store.sttProvider = .localModel
        XCTAssertEqual(store.sttProvider, .localModel)
    }

    func testInvalidSTTProviderFallsBackToDefault() {
        defaults.set("nonexistent", forKey: "stt.provider")
        XCTAssertEqual(store.sttProvider, .whisperAPI)
    }

    // MARK: - LLM Provider

    func testDefaultLLMProvider() {
        XCTAssertEqual(store.llmProvider, .openAICompatible)
    }

    func testSetAndGetLLMProvider() {
        store.llmProvider = .ollama
        XCTAssertEqual(store.llmProvider, .ollama)
    }

    // MARK: - Appearance Mode

    func testDefaultAppearanceMode() {
        XCTAssertEqual(store.appearanceMode, .light)
    }

    func testSetAppearanceMode() {
        store.appearanceMode = .dark
        XCTAssertEqual(store.appearanceMode, .dark)
    }

    func testAppearanceModeChangePostsNotification() {
        let expectation = XCTestExpectation(description: "Notification posted")
        let observer = NotificationCenter.default.addObserver(
            forName: .appearanceModeDidChange,
            object: nil,
            queue: nil
        ) { _ in
            expectation.fulfill()
        }

        store.appearanceMode = .dark
        wait(for: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }

    func testAppearanceModeNoNotificationWhenSameValue() {
        store.appearanceMode = .dark

        var notificationFired = false
        let observer = NotificationCenter.default.addObserver(
            forName: .appearanceModeDidChange,
            object: nil,
            queue: nil
        ) { _ in
            notificationFired = true
        }

        store.appearanceMode = .dark
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(notificationFired)
        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: - Sound Effects

    func testDefaultSoundEffectsEnabled() {
        XCTAssertTrue(store.soundEffectsEnabled)
    }

    func testSetSoundEffectsDisabled() {
        store.soundEffectsEnabled = false
        XCTAssertFalse(store.soundEffectsEnabled)
    }

    // MARK: - Mute System Output

    func testDefaultMuteSystemOutput() {
        XCTAssertFalse(store.muteSystemOutputDuringRecording)
    }

    func testSetMuteSystemOutput() {
        store.muteSystemOutputDuringRecording = true
        XCTAssertTrue(store.muteSystemOutputDuringRecording)
    }

    // MARK: - HistoryRetentionPolicy

    func testRetentionPolicyDays() {
        XCTAssertEqual(HistoryRetentionPolicy.never.days, 0)
        XCTAssertEqual(HistoryRetentionPolicy.oneDay.days, 1)
        XCTAssertEqual(HistoryRetentionPolicy.oneWeek.days, 7)
        XCTAssertEqual(HistoryRetentionPolicy.oneMonth.days, 30)
        XCTAssertNil(HistoryRetentionPolicy.forever.days)
    }

    func testRetentionPolicyTitlesAreNonEmpty() {
        for policy in HistoryRetentionPolicy.allCases {
            XCTAssertFalse(policy.title.isEmpty, "\(policy) title should not be empty")
        }
    }

    func testRetentionPolicyDetailsAreNonEmpty() {
        for policy in HistoryRetentionPolicy.allCases {
            XCTAssertFalse(policy.detail.isEmpty, "\(policy) detail should not be empty")
        }
    }

    func testRetentionPolicyId() {
        for policy in HistoryRetentionPolicy.allCases {
            XCTAssertEqual(policy.id, policy.rawValue)
        }
    }
}
