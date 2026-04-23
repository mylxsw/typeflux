import XCTest
@testable import Typeflux

final class LLMConfigurationValidatorTests: XCTestCase {
    private func makeSettingsStore() -> SettingsStore {
        let suiteName = "LLMConfigurationValidatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return SettingsStore(defaults: defaults)
    }

    // MARK: - openAICompatible + specific providers

    func testOpenAICompatibleWithOpenAI_MissingAPIKey() {
        let store = makeSettingsStore()
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .openAI
        store.llmBaseURL = "https://api.openai.com/v1"
        store.llmModel = "gpt-4"
        store.llmAPIKey = ""

        let validator = LLMConfigurationValidator(settingsStore: store, isLoggedIn: false)
        let status = validator.validate()

        XCTAssertEqual(status, .notConfigured(reason: .missingAPIKey))
    }

    func testOpenAICompatibleWithOpenAI_FullyConfigured() {
        let store = makeSettingsStore()
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .openAI
        store.llmBaseURL = "https://api.openai.com/v1"
        store.llmModel = "gpt-4"
        store.llmAPIKey = "sk-test"

        let validator = LLMConfigurationValidator(settingsStore: store, isLoggedIn: false)
        let status = validator.validate()

        XCTAssertEqual(status, .ready)
    }

    func testOpenAICompatibleWithCustom_MissingBaseURL() {
        let store = makeSettingsStore()
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .custom
        store.llmBaseURL = ""
        store.llmModel = "model"

        let validator = LLMConfigurationValidator(settingsStore: store, isLoggedIn: false)
        let status = validator.validate()

        XCTAssertEqual(status, .notConfigured(reason: .incompleteConfig(details: "Custom LLM base URL or model not configured")))
    }

    func testOpenAICompatibleWithCustom_FullyConfigured() {
        let store = makeSettingsStore()
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .custom
        store.llmBaseURL = "https://example.com/v1"
        store.llmModel = "model"

        let validator = LLMConfigurationValidator(settingsStore: store, isLoggedIn: false)
        let status = validator.validate()

        XCTAssertEqual(status, .ready)
    }

    // MARK: - typefluxCloud

    func testTypefluxCloud_NotLoggedIn() {
        let store = makeSettingsStore()
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .typefluxCloud

        let validator = LLMConfigurationValidator(settingsStore: store, isLoggedIn: false)
        let status = validator.validate()

        XCTAssertEqual(status, .notConfigured(reason: .cloudNotLoggedIn))
    }

    func testTypefluxCloud_LoggedIn() {
        let store = makeSettingsStore()
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .typefluxCloud

        let validator = LLMConfigurationValidator(settingsStore: store, isLoggedIn: true)
        let status = validator.validate()

        XCTAssertEqual(status, .ready)
    }

    // MARK: - freeModel

    func testFreeModel_MissingModel() {
        let store = makeSettingsStore()
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .freeModel
        store.llmModel = ""

        let validator = LLMConfigurationValidator(settingsStore: store, isLoggedIn: false)
        let status = validator.validate()

        XCTAssertEqual(status, .notConfigured(reason: .incompleteConfig(details: "Free model not selected")))
    }

    func testFreeModel_ModelSet() {
        let store = makeSettingsStore()
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .freeModel
        store.llmModel = "test-model"

        let validator = LLMConfigurationValidator(settingsStore: store, isLoggedIn: false)
        let status = validator.validate()

        XCTAssertEqual(status, .ready)
    }

    // MARK: - ollama

    func testOllama_MissingBaseURL() {
        let store = makeSettingsStore()
        store.llmProvider = .ollama
        store.ollamaBaseURL = ""
        store.ollamaModel = "qwen"

        let validator = LLMConfigurationValidator(settingsStore: store, isLoggedIn: false)
        let status = validator.validate()

        XCTAssertEqual(status, .notConfigured(reason: .incompleteConfig(details: "Ollama base URL or model not configured")))
    }

    func testOllama_MissingModel() {
        let store = makeSettingsStore()
        store.llmProvider = .ollama
        store.ollamaBaseURL = "http://localhost:11434"
        store.ollamaModel = ""

        let validator = LLMConfigurationValidator(settingsStore: store, isLoggedIn: false)
        let status = validator.validate()

        XCTAssertEqual(status, .notConfigured(reason: .incompleteConfig(details: "Ollama base URL or model not configured")))
    }

    func testOllama_FullyConfigured() {
        let store = makeSettingsStore()
        store.llmProvider = .ollama
        store.ollamaBaseURL = "http://localhost:11434"
        store.ollamaModel = "qwen"

        let validator = LLMConfigurationValidator(settingsStore: store, isLoggedIn: false)
        let status = validator.validate()

        XCTAssertEqual(status, .ready)
    }
}
