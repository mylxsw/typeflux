@testable import Typeflux
import XCTest

@MainActor
final class ModelRegistryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "model-registry-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testConfigurationHidesEmptyFreeCatalogsWithoutRemovingSavedProviders() throws {
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let stored = library.providers
        XCTAssertEqual(library.configurationProviders.contains { $0.remote == .freeModel },
                       !FreeLLMModelRegistry.suggestedModelNames.isEmpty)
        XCTAssertEqual(ModelAvailability.configurationSpeechProviders.contains(.freeModel),
                       !FreeSTTModelRegistry.suggestedModelNames.isEmpty)
        XCTAssertEqual(library.providers, stored)
        XCTAssertTrue(library.providers.contains { $0.remote == .freeModel })
        XCTAssertTrue(library.configurationProviders.contains { $0.isCloud })
        XCTAssertTrue(ModelAvailability.configurationSpeechProviders.contains(.typefluxOfficial))
        XCTAssertTrue(ModelAvailability.configurationSpeechProviders.contains(.localModel))
    }

    func testMigrationPreservesSelectionsAndEveryConfiguredProvider() throws {
        let settings = SettingsStore(defaults: defaults)
        settings.sttProvider = .aliCloud
        settings.llmProvider = .openAICompatible
        settings.llmRemoteProvider = .anthropic
        settings.llmModel = "existing-claude"
        settings.setLLMModel("existing-openai", for: .openAI)
        defaults.set("cloud:cheap", forKey: "ask.model.default")
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        XCTAssertEqual(settings.sttProvider, .aliCloud)
        XCTAssertEqual(library.defaultReference, "cloud:cheap")
        let (provider, model) = try XCTUnwrap(library.registry.resolve(library.rewriteReference))
        XCTAssertEqual(provider.remote, .anthropic)
        XCTAssertEqual(model.id, "existing-claude")
        XCTAssertEqual(settings.textLLMConfiguration().provider, .anthropic)
        XCTAssertEqual(settings.textLLMConfiguration().model, "existing-claude")
        XCTAssertEqual(library.providers.first { $0.remote == .openAI }?.models.first?.id, "existing-openai")
        let second = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        XCTAssertEqual(second.registry, library.registry)
        XCTAssertEqual(second.rewriteReference, library.rewriteReference)
    }

    func testOllamaMigrationAndDeletedSelectionNeverUsesLegacyModel() throws {
        let settings = SettingsStore(defaults: defaults)
        settings.llmProvider = .ollama
        settings.ollamaModel = "old-ollama"
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        XCTAssertEqual(settings.effectiveLLMProvider, .ollama)
        XCTAssertEqual(settings.resolvedOllamaModel, "old-ollama")
        try library.addModels([.init(id: "new-ollama", name: "New")], providerID: "ollama")
        let model = try XCTUnwrap(library.providers.first { $0.isOllama }?.models.last)
        library.rewriteReference = model.reference
        XCTAssertEqual(settings.resolvedOllamaModel, "new-ollama")
        try library.removeModel(model.reference, providerID: "ollama")
        XCTAssertFalse(settings.isLLMConfigured)
        XCTAssertEqual(library.rewriteReference, model.reference)
        XCTAssertTrue(settings.textLLMConfiguration().model.isEmpty)
    }

    func testCustomMigrationKeepsAccountsAndDoesNotMergeDifferentCredentials() throws {
        let first = AskModelProfile(name: "One", baseURL: "https://example.invalid/v1", model: "m")
        let second = AskModelProfile(name: "Two", baseURL: first.baseURL, model: "m")
        try defaults.set(JSONEncoder().encode([first, second]), forKey: "llm.model.profiles")
        defaults.set(second.reference, forKey: "ask.model.default")
        defaults.set(first.reference, forKey: "llm.profile.reference")
        let library = AskModelLibrary(defaults: defaults)
        for profile in [first, second] {
            let (provider, model) = try XCTUnwrap(library.registry.resolve(profile.reference))
            XCTAssertEqual(provider.credentialAccount, "ask-model-" + profile.id)
            XCTAssertEqual(model.id, profile.model)
        }
        XCTAssertEqual(library.profiles, [first, second])
        XCTAssertEqual(library.defaultReference, second.reference)
        XCTAssertEqual(library.rewriteReference, first.reference)
    }

    func testAddDeduplicatesWithinProviderAndRemovalPreservesReferences() throws {
        let library = AskModelLibrary(defaults: defaults)
        try library.addModels(
            [.init(id: "same", name: "Same"), .init(id: "same", name: "Duplicate")],
            providerID: "openAI"
        )
        try library.addModels([.init(id: "same", name: "Same")], providerID: "anthropic")
        let openAI = try XCTUnwrap(library.providers.first { $0.id == "openAI" })
        let model = try XCTUnwrap(openAI.models.first { $0.id == "same" })
        XCTAssertEqual(openAI.models.filter { $0.id == "same" }.count, 1)
        XCTAssertNotEqual(model.reference, library.providers.first { $0.id == "anthropic" }?.models.first?.reference)
        library.defaultReference = model.reference
        library.rewriteReference = model.reference
        try library.removeModel(model.reference, providerID: openAI.id)
        XCTAssertNil(library.registry.resolve(model.reference))
        XCTAssertEqual(library.defaultReference, model.reference)
        XCTAssertEqual(library.rewriteReference, model.reference)
        XCTAssertThrowsError(try library.addModels([.init(id: " ", name: "")], providerID: openAI.id))
        XCTAssertThrowsError(try library.addModels([], providerID: "missing"))
        XCTAssertThrowsError(try library.removeModel("missing", providerID: "missing"))
    }

    func testSetCapabilityRecordsVisionAndReasoningPerModel() throws {
        let library = AskModelLibrary(defaults: defaults)
        try library.addModels([.init(id: "custom", name: "Custom"), .init(id: "other", name: "Other")],
                              providerID: "openAI")
        let models = try XCTUnwrap(library.providers.first { $0.id == "openAI" }?.models)
        let model = try XCTUnwrap(models.first { $0.id == "custom" })
        let other = try XCTUnwrap(models.first { $0.id == "other" })

        try library.setCapability(\.vision, true, reference: model.reference, providerID: "openAI")
        try library.setCapability(\.reasoning, false, reference: model.reference, providerID: "openAI")
        XCTAssertEqual(library.registry.resolve(model.reference)?.1.vision, true)
        XCTAssertEqual(library.registry.resolve(model.reference)?.1.reasoning, false)
        XCTAssertEqual(library.imageCapability(model.reference), .supported)
        XCTAssertFalse(AskReasoningEffort.isAvailable(for: library.registry.resolve(model.reference)?.1))
        XCTAssertNil(library.registry.resolve(other.reference)?.1.vision)
        XCTAssertNil(library.registry.resolve(other.reference)?.1.reasoning)

        try library.setCapability(\.vision, false, reference: model.reference, providerID: "openAI")
        try library.setCapability(\.reasoning, true, reference: model.reference, providerID: "openAI")
        XCTAssertEqual(library.imageCapability(model.reference), .unsupported)
        XCTAssertTrue(AskReasoningEffort.isAvailable(for: library.registry.resolve(model.reference)?.1))
        // Persisted, not just in memory.
        XCTAssertEqual(ModelRegistry.read(defaults)?.resolve(model.reference)?.1.vision, false)

        XCTAssertThrowsError(try library.setCapability(\.vision, true, reference: "custom:missing", providerID: "openAI"))
        XCTAssertThrowsError(try library.setCapability(\.vision, true, reference: model.reference, providerID: "missing"))
    }

    func testProviderOrderingAndCapabilityReasons() throws {
        let library = AskModelLibrary(defaults: defaults)
        let openAI = try XCTUnwrap(library.providers.first { $0.remote == .openAI })
        XCTAssertEqual(library.unavailableReason(openAI, loggedIn: true), L("models.keyMissing"))
        try library.updateConnection(openAI, baseURL: "https://example.invalid/v1", key: "fixture")
        let available = library.sortedProviders(loggedIn: true)
        XCTAssertEqual(available.first?.remote, .typefluxCloud)
        XCTAssertEqual(available.dropFirst().first?.remote, .openAI)
        var model = try XCTUnwrap(openAI.models.first)
        model.id = "private-house-model"
        XCTAssertNil(library.selectionReason(model, provider: openAI, hasImage: false, loggedIn: true))
        // Unknown vision on the user's own model gets a try, unless a confirmed vision model is required.
        XCTAssertNil(library.selectionReason(model, provider: openAI, hasImage: true, loggedIn: true))
        XCTAssertEqual(
            library.selectionReason(model, provider: openAI, hasImage: true, loggedIn: true, confirmedVision: true),
            L("models.unknownVision")
        )
        var vision = model; vision.vision = true
        XCTAssertNil(library.selectionReason(vision, provider: openAI, hasImage: true, loggedIn: true))
        vision.vision = false
        XCTAssertEqual(
            library.selectionReason(vision, provider: openAI, hasImage: true, loggedIn: true),
            L("models.noVision")
        )
        vision.id = "text-embedding-3-small"
        XCTAssertEqual(
            library.selectionReason(vision, provider: openAI, hasImage: false, loggedIn: true),
            L("models.notChat")
        )
        let cloud = try XCTUnwrap(library.providers.first { $0.isCloud })
        XCTAssertEqual(library.unavailableReason(cloud, loggedIn: false), L("models.login"))
        let ollama = try XCTUnwrap(library.providers.first { $0.isOllama })
        XCTAssertEqual(library.unavailableReason(ollama, loggedIn: true), L("models.ollamaMissing"))
        XCTAssertEqual(ModelAvailability.sorted([1, 2, 3, 4]) { $0.isMultiple(of: 2) }, [2, 4, 1, 3])
    }

    func testPickerHidesUnconfiguredUnavailableAndIncompatibleModels() throws {
        let settings = SettingsStore(defaults: defaults)
        settings.setLLMAPIKey("fixture", for: .openAI)
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let text = RegisteredModel(id: "text", name: "Text", vision: false)
        let vision = RegisteredModel(id: "vision", name: "Vision", vision: true)
        let embedding = RegisteredModel(id: "embedding", name: "Embedding", chat: false)
        try library.addModels([text, vision, embedding], providerID: "openAI")
        let choices = library.selectableProviders(loggedIn: false, hasImage: false)
        XCTAssertFalse(choices.contains { $0.isCloud || $0.isOllama || $0.remote == .anthropic })
        XCTAssertTrue(choices.flatMap(\.models).contains { $0.reference == text.reference })
        XCTAssertFalse(choices.flatMap(\.models).contains { $0.reference == embedding.reference })
        let imageChoices = library.selectableProviders(loggedIn: true, hasImage: true)
        XCTAssertTrue(imageChoices.contains { $0.isCloud })
        // The migrated default model may also qualify through its name; these three must not depend on it.
        let added = [text.reference, vision.reference, embedding.reference]
        XCTAssertEqual(imageChoices.first { $0.remote == .openAI }?.models.map(\.reference).filter(added.contains),
                       [vision.reference])
        settings.setLLMAPIKey("", for: .openAI)
        XCTAssertFalse(library.selectableProviders(loggedIn: false, hasImage: false).contains { $0.remote == .openAI })
        // Configuration remains editable; filtering must not delete saved models.
        XCTAssertTrue(library.providers.contains { $0.remote == .anthropic })
        XCTAssertNotNil(library.registry.resolve(text.reference))
    }

    func testProviderIconsReuseBundledBrandAssets() {
        for provider in StudioModelProviderID.allCases {
            XCTAssertFalse(ModelProviderIcon.symbol(for: provider).isEmpty)
            guard ModelProviderIcon.resourceName(for: provider) != nil else { continue }
            XCTAssertNotNil(ModelProviderIcon.image(for: provider), "Missing asset for \(provider)")
            XCTAssertTrue(ModelProviderIcon.image(for: provider) === ModelProviderIcon.image(for: provider))
        }
        XCTAssertEqual(RegisteredProvider(id: "ollama", name: "Ollama").studioProviderID, .ollama)
        XCTAssertEqual(RegisteredProvider(id: "endpoint:x", name: "Custom").studioProviderID, .customLLM)
        XCTAssertEqual(RegisteredProvider(id: "openAI", name: "OpenAI", remote: .openAI).studioProviderID, .openAI)
    }

    func testAvailabilitySortingEvaluatesEachProviderOnceAndPreservesOrder() {
        var visited: [Int] = []
        let result = ModelAvailability.sorted(Array(0 ..< 100)) {
            visited.append($0)
            return $0.isMultiple(of: 2)
        }
        XCTAssertEqual(visited, Array(0 ..< 100))
        XCTAssertEqual(result, Array(stride(from: 0, to: 100, by: 2)) + Array(stride(from: 1, to: 100, by: 2)))
    }

    func testCloudSpeechAvailableWithLoginOrLocalFallback() {
        let settings = SettingsStore(defaults: defaults)
        for (loggedIn, local) in [(true, false), (true, true), (false, true)] {
            XCTAssertNil(ModelAvailability.speechReason(.typefluxOfficial, settings: settings,
                                                        loggedIn: loggedIn, localModelAvailable: local,
                                                        googleAuthorized: false))
        }
    }

    func testSpeechAvailabilityPreservesUnconfiguredEntries() {
        let settings = SettingsStore(defaults: defaults)
        for provider in [
            STTProvider.whisperAPI,
            .multimodalLLM,
            .aliCloud,
            .doubaoRealtime,
            .googleCloud,
            .groq,
            .soniox,
            .typefluxOfficial,
            .localModel
        ] {
            XCTAssertNotNil(ModelAvailability.speechReason(
                provider,
                settings: settings,
                loggedIn: false,
                localModelAvailable: false,
                googleAuthorized: false
            ))
        }
        settings.whisperAPIKey = "fixture"; settings.whisperBaseURL = "https://example.invalid/v1"; settings
            .whisperModel = "whisper"
        settings.multimodalLLMAPIKey = "fixture"; settings.multimodalLLMBaseURL = "https://example.invalid/v1"; settings
            .multimodalLLMModel = "audio"
        settings.aliCloudAPIKey = "fixture"; settings.doubaoAppID = "fixture"; settings
            .doubaoAccessToken = "fixture"; settings.doubaoResourceID = "fixture"
        settings.googleCloudProjectID = "fixture"; settings.groqSTTAPIKey = "fixture"; settings.sonioxAPIKey = "fixture"
        for provider in STTProvider.allCases where provider != .freeModel {
            XCTAssertNil(ModelAvailability.speechReason(
                provider,
                settings: settings,
                loggedIn: true,
                localModelAvailable: true,
                googleAuthorized: true
            ))
        }
    }

    func testConnectionUpdatesUseOneCredentialAccountAndCatalogInjection() async throws {
        KeychainTokenStore.useInMemoryStoreForTesting = true
        defer { KeychainTokenStore.useInMemoryStoreForTesting = false }
        let stub = RegistryCatalogStub()
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false, catalog: stub)
        let profile = AskModelProfile(name: "Endpoint", baseURL: "https://example.invalid/v1", model: "initial")
        try library.save(profile, key: "old-key")
        defer { KeychainTokenStore.deleteKeychainItem(account: "ask-model-" + profile.id) }
        var provider = try XCTUnwrap(library.registry.resolve(profile.reference)?.0)
        try library.addModels([.init(id: "second", name: "Second")], providerID: provider.id)
        try library.updateConnection(provider, baseURL: "https://new.invalid/v1", key: "new-key")
        provider = try XCTUnwrap(library.registry.resolve(profile.reference)?.0)
        XCTAssertEqual(library.connection(provider, model: provider.models.last).apiKey, "new-key")
        XCTAssertEqual(library.connection(provider).baseURL, "https://new.invalid/v1")
        var renamed = profile; renamed.name = "Renamed"
        try library.save(renamed, key: "new-key")
        XCTAssertEqual(library.registry.resolve(profile.reference)?.0.models.count, 2)
        let models = try await library.loadModels(provider: provider)
        XCTAssertEqual(models.map(\.id), ["loaded"])
        await library.probeOllama()
        XCTAssertTrue(library.ollamaAvailable)
        let local = try XCTUnwrap(library.providers.first { $0.isOllama })
        try library.updateConnection(local, baseURL: "http://localhost:2345", key: "")
        XCTAssertFalse(library.ollamaAvailable)
        XCTAssertEqual(library.settings.ollamaBaseURL, "http://localhost:2345")
        stub.fails = true
        await library.probeOllama()
        XCTAssertFalse(library.ollamaAvailable)
        do { _ = try await library.loadModels(provider: provider); XCTFail("Expected provider error") } catch {}
        let free = try XCTUnwrap(library.providers.first { $0.remote == .freeModel })
        _ = try await library.loadModels(provider: free)
        var empty = RegisteredProvider(id: "empty", name: "Empty", baseURL: "")
        XCTAssertEqual(library.unavailableReason(empty, loggedIn: true), L("models.endpointMissing"))
        empty.baseURL = "https://example.invalid"
        XCTAssertEqual(library.unavailableReason(empty, loggedIn: true), L("models.noModels"))
        XCTAssertThrowsError(try library.updateConnection(empty, baseURL: empty.baseURL, key: ""))
    }

    func testCloudRefreshAddsPublishedModelsWithoutChangingDefaults() async throws {
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        library.defaultReference = "cloud:default"
        try library.removeModel("cloud:default", providerID: "typefluxCloud")
        await library.refresh(api: AskTestAPI(), token: "fixture")
        XCTAssertNotNil(library.registry.resolve("cloud:default"))
        XCTAssertEqual(library.defaultReference, "cloud:default")
        try library.addModels([.init(id: "deep", name: "Deep", reference: "cloud:deep")], providerID: "typefluxCloud")
        library.rewriteReference = "cloud:deep"
        XCTAssertEqual(library.settings.textLLMConfiguration().model, "cloud:deep")
        XCTAssertEqual(library.settings.textLLMConfiguration().provider, .typefluxCloud)
    }

    func testNonVisionSelectionDetachesScreenshotAndDoesNotChangeDefault() async throws {
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        try library.addModels([.init(id: "text-only", name: "Text only", vision: false)], providerID: "openAI")
        let provider = try XCTUnwrap(library.providers.first { $0.remote == .openAI })
        try library.updateConnection(provider, baseURL: "https://example.invalid/v1", key: "fixture")
        let selected = try XCTUnwrap(provider.models.first { $0.id == "text-only" })
        let fixture = try AskTestFixture(modelLibrary: library)
        await fixture.model.prepareLauncher()
        fixture.model.launcherDraft.text = "Describe screenshot"
        fixture.model.launcherDraft.modelRef = selected.reference
        fixture.model.launcherDraft.screenshot = "data:image/png;base64,AAAA"
        fixture.model.launcherDraft.includeScreenshot = true
        XCTAssertFalse(fixture.model.requiresVision(launcher: true))
        XCTAssertFalse(fixture.model.launcherDraft.includeScreenshot)
        XCTAssertNotNil(fixture.model.launcherDraft.screenshot)
        fixture.model.submitLauncher()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        let sends = await fixture.api.sends
        XCTAssertEqual(sends.count, 1)
        XCTAssertNil(sends.first?.image)
        XCTAssertEqual(sends.first?.modelRef, selected.reference)
        XCTAssertEqual(library.defaultReference, "cloud:default")
        XCTAssertEqual(fixture.model.selected?.modelRef, selected.reference)
        XCTAssertNil(fixture.model.error)
        fixture.model.resetSession()
    }

    func testFirstOnboardingChoiceAfterCatalogConstructionIsAdoptedOnce() {
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let settings = library.settings
        settings.llmProvider = .ollama
        settings.ollamaModel = "onboarding-model"
        library.adoptLegacySelectionIfNeeded()
        XCTAssertEqual(library.registry.resolve(library.rewriteReference)?.1.id, "onboarding-model")
        let reference = library.rewriteReference
        settings.ollamaModel = "different-legacy-value"
        library.adoptLegacySelectionIfNeeded()
        XCTAssertEqual(library.rewriteReference, reference)
        XCTAssertEqual(settings.resolvedOllamaModel, "onboarding-model")
    }

    func testRewriteValidationAndMergedPathUseExplicitSelection() throws {
        let settings = SettingsStore(defaults: defaults)
        settings.llmProvider = .openAICompatible
        settings.llmRemoteProvider = .typefluxCloud
        XCTAssertTrue(settings.canUseIntegratedCloudRewrite)
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        XCTAssertFalse(settings.canUseIntegratedCloudRewrite)
        XCTAssertEqual(LLMConfigurationValidator(settingsStore: settings, isLoggedIn: false).validate(),
                       .notConfigured(reason: .cloudNotLoggedIn))
        XCTAssertEqual(LLMConfigurationValidator(settingsStore: settings, isLoggedIn: true).validate(), .ready)
        try library.addModels([.init(id: "selected", name: "Selected")], providerID: "openAI")
        let provider = try XCTUnwrap(library.providers.first { $0.remote == .openAI })
        library.rewriteReference = try XCTUnwrap(provider.models.first?.reference)
        XCTAssertEqual(LLMConfigurationValidator(settingsStore: settings, isLoggedIn: true).validate(),
                       .notConfigured(reason: .missingAPIKey))
        try library.updateConnection(provider, baseURL: "https://example.invalid/v1", key: "fixture")
        XCTAssertEqual(LLMConfigurationValidator(settingsStore: settings, isLoggedIn: false).validate(), .ready)
        try library.removeModel(library.rewriteReference, providerID: provider.id)
        XCTAssertNotEqual(LLMConfigurationValidator(settingsStore: settings, isLoggedIn: true).validate(), .ready)
    }

    func testCorruptRegistryDoesNotOverwriteStoredBytes() {
        let data = Data("broken".utf8)
        defaults.set(data, forKey: ModelRegistry.storageKey)
        let library = AskModelLibrary(defaults: defaults)
        XCTAssertNotNil(library.catalogError)
        XCTAssertEqual(defaults.data(forKey: ModelRegistry.storageKey), data)
    }
}

private final class RegistryCatalogStub: ProviderModelCatalog {
    var fails = false
    func models(provider _: RegisteredProvider,
                connection _: SettingsStore.TextLLMConfiguration) async throws -> [RegisteredModel] {
        if fails {
            throw AskLocalError.message("Fixture failure")
        }
        return [.init(id: "loaded", name: "Loaded")]
    }
}
