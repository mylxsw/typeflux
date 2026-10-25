@testable import Typeflux
import XCTest

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
        let now = Date(timeIntervalSince1970: 1000)
        let policy = LLMConfigurationReminderPolicy(settingsStore: store, now: { now })

        let presentation = policy.presentation(for: .notConfigured(reason: .cloudNotLoggedIn))

        XCTAssertEqual(presentation, .actionDialog)
        XCTAssertEqual(store.lastTypefluxCloudLoginReminderAt, now)
    }

    func testTypefluxCloudLoginReminderIsSuppressedWithinSixHours() {
        let store = makeSettingsStore()
        let lastShownAt = Date(timeIntervalSince1970: 1000)
        store.lastTypefluxCloudLoginReminderAt = lastShownAt
        let policy = LLMConfigurationReminderPolicy(
            settingsStore: store,
            now: {
                lastShownAt.addingTimeInterval(6 * 60 * 60 - 1)
            }
        )

        let presentation = policy.presentation(for: .notConfigured(reason: .cloudNotLoggedIn))

        XCTAssertEqual(presentation, .suppressed)
        XCTAssertEqual(store.lastTypefluxCloudLoginReminderAt, lastShownAt)
    }

    func testTypefluxCloudLoginReminderAppliesWhenCloudASRFallsBackLocally() {
        let store = makeSettingsStore()
        store.llmRemoteProvider = .openAI
        let lastShownAt = Date(timeIntervalSince1970: 1000)
        store.lastTypefluxCloudLoginReminderAt = lastShownAt
        let policy = LLMConfigurationReminderPolicy(
            settingsStore: store,
            now: {
                lastShownAt.addingTimeInterval(6 * 60 * 60 - 1)
            }
        )

        let presentation = policy.presentation(for: .notConfigured(reason: .cloudNotLoggedIn))

        XCTAssertEqual(presentation, .suppressed)
        XCTAssertEqual(store.lastTypefluxCloudLoginReminderAt, lastShownAt)
    }

    func testTypefluxCloudLoginReminderShowsActionDialogAfterSixHours() {
        let store = makeSettingsStore()
        let lastShownAt = Date(timeIntervalSince1970: 1000)
        let now = lastShownAt.addingTimeInterval(6 * 60 * 60)
        store.lastTypefluxCloudLoginReminderAt = lastShownAt
        let policy = LLMConfigurationReminderPolicy(settingsStore: store, now: { now })

        let presentation = policy.presentation(for: .notConfigured(reason: .cloudNotLoggedIn))

        XCTAssertEqual(presentation, .actionDialog)
        XCTAssertEqual(store.lastTypefluxCloudLoginReminderAt, now)
    }

    func testNonCloudLoginFailuresStillUseActionDialog() {
        let store = makeSettingsStore()
        store.llmRemoteProvider = .openAI
        let policy = LLMConfigurationReminderPolicy(settingsStore: store, now: { Date(timeIntervalSince1970: 1000) })

        let presentation = policy.presentation(for: .notConfigured(reason: .missingAPIKey))

        XCTAssertEqual(presentation, .actionDialog)
        XCTAssertNil(store.lastTypefluxCloudLoginReminderAt)
    }
    func testRepeatedAttemptsDoNotExtendCooldown() {
        let store = makeSettingsStore()
        let firstShownAt = Date(timeIntervalSince1970: 1000)
        var currentTime = firstShownAt
        let policy = LLMConfigurationReminderPolicy(settingsStore: store, now: { currentTime })
        XCTAssertEqual(policy.presentation(for: .notConfigured(reason: .cloudNotLoggedIn)), .actionDialog)

        for hour in 1...5 {
            currentTime = firstShownAt.addingTimeInterval(Double(hour) * 60 * 60)
            XCTAssertEqual(policy.presentation(for: .notConfigured(reason: .cloudNotLoggedIn)), .suppressed)
            XCTAssertEqual(store.lastTypefluxCloudLoginReminderAt, firstShownAt)
        }
        currentTime = firstShownAt.addingTimeInterval(6 * 60 * 60)
        XCTAssertEqual(policy.presentation(for: .notConfigured(reason: .cloudNotLoggedIn)), .actionDialog)
    }

    func testCooldownSurvivesSettingsReload() {
        let suiteName = "LLMConfigurationReminderPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstShownAt = Date(timeIntervalSince1970: 1000)
        let initialPolicy = LLMConfigurationReminderPolicy(
            settingsStore: SettingsStore(defaults: defaults), now: { firstShownAt }
        )
        XCTAssertEqual(initialPolicy.presentation(for: .notConfigured(reason: .cloudNotLoggedIn)), .actionDialog)
        let reloadedPolicy = LLMConfigurationReminderPolicy(
            settingsStore: SettingsStore(defaults: UserDefaults(suiteName: suiteName)!),
            now: { firstShownAt.addingTimeInterval(60) }
        )
        XCTAssertEqual(reloadedPolicy.presentation(for: .notConfigured(reason: .cloudNotLoggedIn)), .suppressed)
    }

}
