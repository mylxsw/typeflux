import Foundation
import Testing
@testable import Typeflux

/// Explicitly opted-in smoke test. The private context comes from the signed app,
/// is never logged, and contains only model settings and noninteractive credentials.
/// This test interprets text; it never constructs a reminder-writing service.
@Suite(.exclusiveUIState)
struct AppleReminderLiveModelTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_LIVE_REMINDER_CONTEXT"] != nil))
    @MainActor func configuredModelUnderstandsTheSubmittedSentence() async throws {
        struct Context: Decodable {
            var preferences: String
            var keychain: [String: String]
            var apiEnvironment: [String: String]
        }
        let path = try #require(ProcessInfo.processInfo.environment["TYPEFLUX_LIVE_REMINDER_CONTEXT"])
        let context = try JSONDecoder().decode(Context.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let preferences = try #require(Data(base64Encoded: context.preferences))
        let values = try #require(PropertyListSerialization.propertyList(from: preferences, format: nil) as? [String: Any])
        let name = "Typeflux.ReminderLiveModel.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.setPersistentDomain(values, forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        var savedEnvironment: [String: String] = [:]
        for (key, value) in context.apiEnvironment {
            savedEnvironment[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
        defer {
            for key in context.apiEnvironment.keys {
                if let value = savedEnvironment[key] { setenv(key, value, 1) }
                else { unsetenv(key) }
            }
        }
        let previousMode = KeychainTokenStore.useInMemoryStoreForTesting
        let previousMemory = KeychainTokenStore.inMemoryValues
        KeychainTokenStore.useInMemoryStoreForTesting = true
        KeychainTokenStore.inMemoryValues = [:]
        let auth = AuthState.shared
        let previousToken = auth.inMemorySessionToken
        defer {
            auth.inMemorySessionToken = previousToken
            KeychainTokenStore.inMemoryValues = previousMemory
            KeychainTokenStore.useInMemoryStoreForTesting = previousMode
        }
        KeychainTokenStore.inMemoryValues = context.keychain.compactMapValues { Data(base64Encoded: $0) }
        struct Session: Decodable { var token: String; var expiresAt: Int }
        if let data = KeychainTokenStore.inMemoryValues["session"],
           let session = try? JSONDecoder().decode(Session.self, from: data) {
            auth.inMemorySessionToken = (session.token, session.expiresAt)
        }
        let settings = SettingsStore(defaults: defaults)
        let service = LLMRouter(settingsStore: settings,
            openAICompatible: OpenAICompatibleLLMService(settingsStore: settings),
            ollama: OllamaLLMService(settingsStore: settings, modelManager: OllamaLocalModelManager()))
        let now = Date(), calendar = Calendar.current
        let interpreter = AppleReminderInterpreter(generator: AskLLMTextGenerator(service: service))
        let result: AppleReminderInterpreter.Resolution
        do {
            result = try await interpreter.resolve("明天下午提醒我吃饭", now: now,
                calendar: calendar, language: .simplifiedChinese)
        } catch {
            // Transport errors may include provider responses; keep credentials out of test output.
            Issue.record("Configured model did not complete (\(type(of: error))).")
            return
        }
        guard case let .suggested(draft) = result else {
            Issue.record("A vague afternoon must produce a time suggestion."); return
        }
        #expect(draft.title.contains("吃饭"))
        let due = try #require(draft.due)
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: now))
        #expect(calendar.isDate(due, inSameDayAs: tomorrow))
        #expect(calendar.component(.hour, from: due) == 15 && calendar.component(.minute, from: due) == 0)
    }
}
