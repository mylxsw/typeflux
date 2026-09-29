import XCTest
@testable import Typeflux

@MainActor
final class AskModelLibraryTests: XCTestCase {
    func testKeysStayOutOfMetadataAndRewriteUsesChosenProfile() throws {
        KeychainTokenStore.useInMemoryStoreForTesting = true
        defer { KeychainTokenStore.useInMemoryStoreForTesting = false }
        let suite = "ask-profile-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let profile = AskModelProfile(name: "My API", baseURL: "https://example.invalid/v1", model: "my-model")
        try library.save(profile, key: "fixture-secret")
        defer { KeychainTokenStore.deleteKeychainItem(account: "ask-model-" + profile.id) }
        let encoded = try XCTUnwrap(defaults.data(forKey: "llm.model.profiles"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("fixture-secret"))
        XCTAssertEqual(AskModelLibrary.key(for: profile), "fixture-secret")
        XCTAssertEqual(AskModelLibrary.readProfiles(defaults), [profile])
        library.defaultReference = profile.reference
        library.rewriteReference = profile.reference
        let store = SettingsStore(defaults: defaults)
        let configuration = store.textLLMConfiguration()
        XCTAssertEqual(configuration.provider, .custom)
        XCTAssertEqual(configuration.model, profile.model)
        XCTAssertEqual(configuration.baseURL, profile.baseURL)
        XCTAssertEqual(configuration.apiKey, "fixture-secret")
        XCTAssertTrue(store.isLLMConfigured)
        library.remove(profile)
        XCTAssertTrue(library.profiles.isEmpty)
        XCTAssertEqual(AskModelLibrary.key(for: profile), "")
        XCTAssertEqual(library.defaultReference, profile.reference)
        XCTAssertFalse(store.isLLMConfigured)
        XCTAssertTrue(store.textLLMConfiguration().model.isEmpty)
    }

    func testExistingOpenAICompatibleConfigurationCanBeImportedWithoutDuplicates() throws {
        KeychainTokenStore.useInMemoryStoreForTesting = true
        defer { KeychainTokenStore.useInMemoryStoreForTesting = false }
        let suite = "ask-import-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .custom
        store.llmBaseURL = "https://example.invalid/v1"
        store.llmModel = "existing-model"
        store.llmAPIKey = "fixture-import-key"
        let library = AskModelLibrary(defaults: defaults)
        try library.importConfiguredProfile()
        try library.importConfiguredProfile()
        XCTAssertEqual(library.profiles.count, 1)
        let profile = try XCTUnwrap(library.profiles.first)
        XCTAssertEqual(profile.model, "existing-model")
        XCTAssertEqual(AskModelLibrary.key(for: profile), "fixture-import-key")
        library.remove(profile)
        store.llmRemoteProvider = .typefluxCloud
        XCTAssertNil(library.configuredProfile)
        XCTAssertThrowsError(try library.importConfiguredProfile())
    }

    func testInvalidProfileDoesNotWriteCredentialsOrMetadata() throws {
        KeychainTokenStore.useInMemoryStoreForTesting = true
        defer { KeychainTokenStore.useInMemoryStoreForTesting = false }
        let suite = "ask-profile-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = AskModelLibrary(defaults: defaults)
        let profile = AskModelProfile(name: "", baseURL: "http://insecure.invalid", model: "")
        XCTAssertThrowsError(try library.save(profile, key: "secret"))
        XCTAssertTrue(library.profiles.isEmpty)
        XCTAssertNil(defaults.data(forKey: "llm.model.profiles"))
        XCTAssertEqual(AskModelLibrary.key(for: profile), "")
        defaults.set(Data("invalid".utf8), forKey: "llm.model.profiles")
        XCTAssertTrue(AskModelLibrary.readProfiles(defaults).isEmpty)
    }
}
