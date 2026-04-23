@testable import Typeflux
import XCTest

final class SettingsStoreLLMConfigurationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsStoreLLMConfigurationTests-\(UUID().uuidString)"
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

    // MARK: - Fresh defaults

    func testFreshInstallDefaultsAreNotConfigured() {
        // Fresh install: openAICompatible + openAI provider with empty baseURL/model/key.
        XCTAssertFalse(store.isLLMConfigured)
    }

    // MARK: - typefluxCloud

    func testTypefluxCloudIsAlwaysConfigured() {
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .typefluxCloud
        XCTAssertTrue(store.isLLMConfigured)
    }

    // MARK: - custom provider

    func testCustomProviderRequiresBaseURLAndModelButNotAPIKey() {
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .custom
        XCTAssertFalse(store.isLLMConfigured, "Empty base URL + model should not count as configured")

        store.setLLMBaseURL("https://example.com/v1", for: .custom)
        XCTAssertFalse(store.isLLMConfigured, "Base URL alone is insufficient")

        store.setLLMModel("my-model", for: .custom)
        XCTAssertTrue(store.isLLMConfigured, "Custom provider should not require an API key")
    }

    // MARK: - freeModel

    func testFreeModelRequiresOnlyModelName() {
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .freeModel
        // Free model resolves baseURL/apiKey from its registry as long as a model name is set.
        if let firstModel = FreeLLMModelRegistry.suggestedModelNames.first {
            store.setLLMModel(firstModel, for: .freeModel)
            XCTAssertTrue(store.isLLMConfigured)
        }
    }

    // MARK: - remote providers requiring API key

    func testOpenAIRequiresBaseURLModelAndAPIKey() {
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .openAI
        // Default base URL is non-empty, default model is non-empty — only API key is missing.
        XCTAssertFalse(store.isLLMConfigured, "OpenAI without API key should not be configured")

        store.setLLMAPIKey("sk-test", for: .openAI)
        XCTAssertTrue(store.isLLMConfigured, "OpenAI with API key should be configured")
    }

    func testAnthropicRequiresAPIKey() {
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .anthropic
        XCTAssertFalse(store.isLLMConfigured)

        store.setLLMAPIKey("sk-ant-test", for: .anthropic)
        XCTAssertTrue(store.isLLMConfigured)
    }

    func testWhitespaceOnlyAPIKeyIsNotConfigured() {
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .openAI
        store.setLLMAPIKey("   ", for: .openAI)
        XCTAssertFalse(store.isLLMConfigured)
    }

    // MARK: - applyDefaultPersonaIfLLMConfigured

    func testApplyDefaultPersonaSkipsWhenLLMNotConfigured() {
        // Fresh install: openAI provider with no API key → not configured.
        let applied = store.applyDefaultPersonaIfLLMConfigured()

        XCTAssertFalse(applied)
        XCTAssertFalse(store.personaRewriteEnabled)
        XCTAssertEqual(store.activePersonaID, "")
        XCTAssertFalse(store.personaSelectionIsExplicit)
    }

    func testApplyDefaultPersonaAppliesWhenLLMConfiguredAndNoPriorChoice() {
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .typefluxCloud

        let applied = store.applyDefaultPersonaIfLLMConfigured()

        XCTAssertTrue(applied)
        XCTAssertTrue(store.personaRewriteEnabled)
        XCTAssertEqual(store.activePersonaID, SettingsStore.defaultPersonaID.uuidString)
        XCTAssertTrue(store.personaSelectionIsExplicit)
    }

    func testApplyDefaultPersonaSkipsAfterUserExplicitlyChoseNone() {
        // User explicitly turns persona off.
        store.applyPersonaSelection(nil)
        XCTAssertTrue(store.personaSelectionIsExplicit)

        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .typefluxCloud

        let applied = store.applyDefaultPersonaIfLLMConfigured()

        XCTAssertFalse(applied)
        XCTAssertFalse(store.personaRewriteEnabled)
        XCTAssertEqual(store.activePersonaID, "")
    }

    func testApplyDefaultPersonaSkipsAfterUserPickedDifferentPersona() {
        let customID = UUID()
        store.applyPersonaSelection(customID)

        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .typefluxCloud

        let applied = store.applyDefaultPersonaIfLLMConfigured()

        XCTAssertFalse(applied)
        XCTAssertEqual(store.activePersonaID, customID.uuidString)
    }

    func testApplyDefaultPersonaIsIdempotent() {
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .typefluxCloud

        XCTAssertTrue(store.applyDefaultPersonaIfLLMConfigured())
        // Second call is a no-op because personaSelectionIsExplicit is now true.
        XCTAssertFalse(store.applyDefaultPersonaIfLLMConfigured())
        XCTAssertEqual(store.activePersonaID, SettingsStore.defaultPersonaID.uuidString)
    }

    func testApplyPersonaSelectionMarksChoiceExplicit() {
        XCTAssertFalse(store.personaSelectionIsExplicit)

        store.applyPersonaSelection(UUID())
        XCTAssertTrue(store.personaSelectionIsExplicit)
    }

    // MARK: - Ollama

    func testOllamaRequiresBaseURLAndModel() {
        store.llmProvider = .ollama
        // Default ollamaBaseURL = "http://127.0.0.1:11434", default ollamaModel = "qwen3.5:7b"
        // So fresh Ollama defaults are considered configured (local-only, no key).
        XCTAssertTrue(store.isLLMConfigured)

        store.ollamaModel = ""
        XCTAssertFalse(store.isLLMConfigured)

        store.ollamaModel = "llama3"
        store.ollamaBaseURL = ""
        XCTAssertFalse(store.isLLMConfigured)
    }
}
