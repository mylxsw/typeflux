import XCTest
@testable import Typeflux

final class LLMConfigurationReminderPolicyTests: XCTestCase {
    private func makeSettingsStore() -> SettingsStore {
        let suiteName = "LLMConfigurationReminderPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(defaults: defaults)
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .typefluxCloud
        return store
    }

    func testFirstTypefluxCloudLoginReminderShowsActionDialogAndStoresTimestamp() {
        let store = makeSettingsStore()
        let now = Date(timeIntervalSince1970: 1_000)
        let policy = LLMConfigurationReminderPolicy(settingsStore: store, now: { now })

        let presentation = policy.presentation(for: .notConfigured(reason: .cloudNotLoggedIn))

        XCTAssertEqual(presentation, .actionDialog)
        XCTAssertEqual(store.lastTypefluxCloudLoginReminderAt, now)
    }

    func testTypefluxCloudLoginReminderUsesPassiveNoticeWithinThreeHours() {
        let store = makeSettingsStore()
        let lastShownAt = Date(timeIntervalSince1970: 1_000)
        store.lastTypefluxCloudLoginReminderAt = lastShownAt
        let policy = LLMConfigurationReminderPolicy(
            settingsStore: store,
            now: { lastShownAt.addingTimeInterval(LLMConfigurationReminderPolicy.typefluxCloudLoginReminderInterval - 1) },
        )

        let presentation = policy.presentation(for: .notConfigured(reason: .cloudNotLoggedIn))

        XCTAssertEqual(presentation, .passiveNotice)
        XCTAssertEqual(store.lastTypefluxCloudLoginReminderAt, lastShownAt)
    }

    func testTypefluxCloudLoginReminderShowsActionDialogAfterThreeHours() {
        let store = makeSettingsStore()
        let lastShownAt = Date(timeIntervalSince1970: 1_000)
        let now = lastShownAt.addingTimeInterval(LLMConfigurationReminderPolicy.typefluxCloudLoginReminderInterval)
        store.lastTypefluxCloudLoginReminderAt = lastShownAt
        let policy = LLMConfigurationReminderPolicy(settingsStore: store, now: { now })

        let presentation = policy.presentation(for: .notConfigured(reason: .cloudNotLoggedIn))

        XCTAssertEqual(presentation, .actionDialog)
        XCTAssertEqual(store.lastTypefluxCloudLoginReminderAt, now)
    }

    func testNonCloudLoginFailuresStillUseActionDialog() {
        let store = makeSettingsStore()
        store.llmRemoteProvider = .openAI
        let policy = LLMConfigurationReminderPolicy(settingsStore: store, now: { Date(timeIntervalSince1970: 1_000) })

        let presentation = policy.presentation(for: .notConfigured(reason: .missingAPIKey))

        XCTAssertEqual(presentation, .actionDialog)
        XCTAssertNil(store.lastTypefluxCloudLoginReminderAt)
    }
}
