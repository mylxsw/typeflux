import SwiftUI
@testable import Typeflux
import XCTest

@MainActor
final class AskImageSettingsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var values: [String: String] = [:]
    private var failWrites = false

    override func setUp() {
        suite = "image-settings-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private var store: AskImageSettings {
        .init(defaults: defaults, keys: .init(read: { self.values[$0] ?? "" }, write: {
            if self.failWrites {
                throw AskImageError.keychain
            }
            self.values[$0] = $1
        }))
    }

    func testKeychainRoundTripUpdateAndRemoval() throws {
        let account = "image-generation-test-" + UUID().uuidString
        let keys = AskImageKeyStore.live
        defer { try? keys.write(account, "") }
        XCTAssertEqual(keys.read(account), "")
        try keys.write(account, "test-value")
        XCTAssertEqual(keys.read(account), "test-value")
        try keys.write(account, "updated-test-value")
        XCTAssertEqual(keys.read(account), "updated-test-value")
        try keys.write(account, "")
        XCTAssertEqual(keys.read(account), "")
        XCTAssertNoThrow(try keys.write(account, ""))
    }

    func testIndependentProviderProfilesAndCredentialsNeverEnterDefaults() throws {
        let store = store
        XCTAssertFalse(store.enabled)
        XCTAssertFalse(store.isReady)
        for provider in AskImageProvider.allCases {
            var config = AskImageConfiguration.preset(provider)
            config.model = "my-custom-2099-model"
            try store.save(config, key: "  secret-" + provider.rawValue + "  ")
            store.enabled = true
            XCTAssertTrue(store.isReady)
            XCTAssertEqual(store.configuration.model, config.model)
            XCTAssertEqual(store.key(for: config), "secret-" + provider.rawValue)
            XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("secret-"))
        }
        store.provider = .google
        XCTAssertEqual(store.configuration.model, "my-custom-2099-model")
        var config = store.configuration
        config.baseURL = "https://other.example/v1"
        XCTAssertEqual(store.key(for: config), "")
        XCTAssertNotEqual(AskImageSettings.credentialID(config), AskImageSettings.credentialID(store.configuration))
        defaults.set(Data("broken".utf8), forKey: "ask.imageGeneration.google")
        XCTAssertEqual(store.configuration, .preset(.google))
        failWrites = true
        XCTAssertThrowsError(try store.save(config, key: "secret"))
        XCTAssertEqual(store.configuration, .preset(.google))
    }

    func testRefreshNeverChangesManualSelectionAndFailureKeepsSuggestions() async {
        let model = AskImageSettingsModel(store: store) { _, _ in ["new-image-model", "other-image"] }
        model.select(.google)
        model.key = "key"
        model.configuration.model = "manual-next-generation"
        model.refresh()
        for _ in 0 ..< 100 where model.loading {
            await Task.yield()
        }
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.models.contains("new-image-model"))
        XCTAssertEqual(model.configuration.model, "manual-next-generation")
        model.setEnabled(true); model.save()
        XCTAssertTrue(store.isReady)
        XCTAssertEqual(store.configuration.model, "manual-next-generation")
        model.configuration.model = ""
        model.save()
        XCTAssertEqual(model.notice, AskImageError.configuration.localizedDescription)
        model.select(.bailian)
        XCTAssertEqual(model.configuration, .preset(.bailian))
        model.key = "not-saved"
        model.setEndpoint(model.configuration.baseURL)
        XCTAssertEqual(model.key, "not-saved")
        model.setEndpoint("https://another.example/v1")
        XCTAssertEqual(model.key, "")
        let failed = AskImageSettingsModel(store: store) { _, _ in throw URLError(.notConnectedToInternet) }
        failed.refresh()
        for _ in 0 ..< 100 where failed.loading {
            await Task.yield()
        }
        XCTAssertEqual(failed.models, store.provider.suggestedModels)
        XCTAssertEqual(failed.notice, L("imagegen.models.failed"))
    }

    func testLateDiscoveryCannotReplaceAnotherProviderOrEditedConfiguration() async {
        let gate = ImageDiscoveryGate()
        let model = AskImageSettingsModel(store: store) { _, _ in await gate.wait() }
        model.refresh()
        await gate.started()
        model.select(.openAI)
        await gate.resume()
        for _ in 0 ..< 30 {
            await Task.yield()
        }
        XCTAssertEqual(model.models, AskImageProvider.openAI.suggestedModels)
        XCTAssertFalse(model.loading)
        model.refresh()
        await gate.started()
        model.configuration.model = "new-custom-value"
        await gate.resume()
        for _ in 0 ..< 100 where model.loading {
            await Task.yield()
        }
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.configuration.model, "new-custom-value")
        XCTAssertFalse(model.models.contains("late-result"))
    }

    func testSwitchAppliesImmediatelyWithoutSavingConnectionDraft() throws {
        let config = AskImageConfiguration.preset(.google)
        try store.save(config, key: "saved-key")
        let model = AskImageSettingsModel(store: store)
        XCTAssertFalse(model.hasChanges)
        XCTAssertEqual(model.status.level, .off)
        model.configuration.model = "unsaved-future-model"
        model.key = "unsaved-key"
        model.setEnabled(true)
        XCTAssertTrue(store.enabled)
        XCTAssertEqual(model.status.level, .ready)
        XCTAssertEqual(store.configuration, config)
        XCTAssertEqual(store.key(for: config), "saved-key")
        model.setEnabled(false)
        XCTAssertFalse(store.enabled)
        XCTAssertFalse(store.isReady)
        XCTAssertEqual(model.status.level, .off)
        XCTAssertTrue(model.hasChanges)
        model.save()
        XCTAssertFalse(store.enabled)
        XCTAssertFalse(model.hasChanges)
        XCTAssertEqual(store.configuration.model, "unsaved-future-model")
        XCTAssertEqual(store.key(for: config), "unsaved-key")
        XCTAssertFalse(model.noticeIsError)
    }

    func testSaveFailureRetainsDraftAndProviderSelectionRequiresSave() {
        let model = AskImageSettingsModel(store: store)
        model.setEnabled(true)
        XCTAssertEqual(model.status.level, .attention)
        model.key = "test-key"
        failWrites = true
        model.save()
        XCTAssertTrue(model.noticeIsError)
        XCTAssertTrue(model.hasChanges)
        XCTAssertEqual(model.status.level, .attention)
        XCTAssertEqual(model.key, "test-key")
        failWrites = false
        model.save()
        XCTAssertFalse(model.hasChanges)
        XCTAssertFalse(model.noticeIsError)
        XCTAssertEqual(model.status.level, .ready)
        model.select(.google)
        XCTAssertTrue(model.hasChanges)
        XCTAssertEqual(store.provider, .volcengine)
        model.key = "google-key"
        model.configuration.model = "future-banana-model"
        model.save()
        XCTAssertFalse(model.hasChanges)
        XCTAssertEqual(store.provider, .google)
        XCTAssertEqual(store.configuration.model, "future-banana-model")
        model.configuration.model = ""
        model.save()
        XCTAssertTrue(model.noticeIsError)
        XCTAssertTrue(model.hasChanges)
        XCTAssertEqual(store.configuration.model, "future-banana-model")
        model.clearNotice()
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.noticeIsError)
    }

    func testProviderSwitchRestoresUnsavedConfigurationAndSecretWithoutPersisting() {
        let model = AskImageSettingsModel(store: store)
        let original = model.configuration
        model.configuration.model = "draft-custom-model"
        model.configuration.size = "2048x2048"
        model.key = "draft-first-key"
        model.select(.google)
        model.configuration.model = "draft-google-model"
        model.key = "draft-google-key"
        model.select(original.provider)
        XCTAssertEqual(model.configuration.model, "draft-custom-model")
        XCTAssertEqual(model.configuration.size, "2048x2048")
        XCTAssertEqual(model.key, "draft-first-key")
        XCTAssertTrue(model.hasChanges)
        XCTAssertEqual(store.configuration, original)
        XCTAssertEqual(store.key(for: original), "")
        model.select(.google)
        XCTAssertEqual(model.configuration.model, "draft-google-model")
        XCTAssertEqual(model.key, "draft-google-key")
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("draft-"))
    }

    func testSavingOneProviderKeepsOtherDraftAndRestoresSavedBaseline() {
        let model = AskImageSettingsModel(store: store)
        let first = model.configuration.provider
        model.key = "first-key"
        model.configuration.model = "first-draft-model"
        model.select(.google)
        model.key = "google-key"
        model.save()
        XCTAssertFalse(model.hasChanges)
        model.select(first)
        XCTAssertEqual(model.configuration.model, "first-draft-model")
        XCTAssertTrue(model.hasChanges)
        model.select(.google)
        XCTAssertFalse(model.hasChanges)
        XCTAssertEqual(model.key, "google-key")
        model.select(first)
        model.save()
        XCTAssertFalse(model.hasChanges)
        model.select(.google)
        XCTAssertTrue(model.hasChanges, "Switching the active provider still needs Save")
        model.save()
        XCTAssertFalse(model.hasChanges)
    }

    func testFailedSaveDraftSurvivesSwitchButNewWindowLoadsOnlySavedValues() {
        let model = AskImageSettingsModel(store: store)
        let first = model.configuration.provider
        model.key = "unsaved-key"
        model.configuration.baseURL = "https://draft.example/v1"
        failWrites = true
        model.save()
        XCTAssertTrue(model.noticeIsError)
        model.select(.google)
        model.select(first)
        XCTAssertEqual(model.key, "unsaved-key")
        XCTAssertEqual(model.configuration.baseURL, "https://draft.example/v1")
        XCTAssertTrue(model.hasChanges)
        let nextWindow = AskImageSettingsModel(store: store)
        XCTAssertEqual(nextWindow.configuration, .preset(first))
        XCTAssertEqual(nextWindow.key, "")
        XCTAssertFalse(nextWindow.hasChanges)
    }

    func testSelectingSameProviderKeepsDraftAndDiscoveryResults() async {
        let model = AskImageSettingsModel(store: store) { _, _ in ["discovered-image"] }
        model.key = "draft-key"
        model.refresh()
        for _ in 0 ..< 100 where model.loading {
            await Task.yield()
        }
        model.select(model.configuration.provider)
        XCTAssertEqual(model.key, "draft-key")
        XCTAssertTrue(model.models.contains("discovered-image"))
        model.select(.google)
        model.select(.volcengine)
        XCTAssertTrue(model.models.contains("discovered-image"))
    }

    func testImageCapabilityStatesAndSettingsRender() throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        var inputs = AgentCapabilityInputs()
        XCTAssertEqual(AgentCapabilityStatus.status(of: .imageGeneration, inputs: inputs).level, .off)
        inputs.imageGenerationEnabled = true
        XCTAssertEqual(AgentCapabilityStatus.status(of: .imageGeneration, inputs: inputs).level, .attention)
        inputs.imageGenerationReady = true
        XCTAssertEqual(AgentCapabilityStatus.status(of: .imageGeneration, inputs: inputs).level, .ready)
        XCTAssertEqual(AgentSettingsPane.imageGeneration.capability, .imageGeneration)
        XCTAssertEqual(AgentCapability.imageGeneration.pane, .imageGeneration)
        for provider in AskImageProvider.allCases {
            store.provider = provider
            store.enabled = true
            try render(AskImageSettingsView(store: store), name: provider.rawValue)
        }
    }

    func testAdvancedOptionsAndFeedbackRenderInBothAppearances() throws {
        for provider in AskImageProvider.allCases {
            let model = AskImageSettingsModel(store: store)
            model.select(provider)
            model.configuration.size = provider == .google ? "2K" : "1024x1024"
            model.configuration.quality = "high"
            model.configuration.routingProvider = "example-provider"
            model.key = "test-key"
            model.save()
            XCTAssertFalse(model.noticeIsError)
            try render(AskImageSettingsView(model: model), name: provider.rawValue + "-advanced", dark: true)
            model.setEnabled(true)
            model.configuration.model = ""
            model.save()
            XCTAssertTrue(model.noticeIsError)
            try render(AskImageSettingsView(model: model), name: provider.rawValue + "-error")
            model.clearNotice()
            model.loading = true
            try render(AskImageSettingsView(model: model), name: provider.rawValue + "-loading")
        }
    }

    private func render(_ content: AskImageSettingsView, name: String, dark: Bool = false) throws {
        let view = NSHostingView(rootView: content.padding(24)
            .frame(width: 880, height: 900, alignment: .topLeading)
            .background(dark ? Color.black : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = CGRect(x: 0, y: 0, width: 880, height: 900)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.appearance = view.appearance
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_IMAGEGEN_SCREENSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}

private actor ImageDiscoveryGate {
    private var continuation: CheckedContinuation<[String], Never>?
    func wait() async -> [String] {
        await withCheckedContinuation { continuation = $0 }
    }

    func started() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume(returning: ["late-result"]); continuation = nil
    }
}
