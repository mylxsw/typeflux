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
        model.enabled = true; model.save()
        XCTAssertTrue(store.isReady)
        XCTAssertEqual(store.configuration.model, "manual-next-generation")
        model.configuration.model = ""
        model.save()
        XCTAssertEqual(model.notice, AskImageError.configuration.localizedDescription)
        model.select(.bailian)
        XCTAssertEqual(model.configuration, .preset(.bailian))
        model.key = "not-saved"
        model.endpointChanged()
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
            let view = NSHostingView(rootView: AskImageSettingsView(store: store).padding(24)
                .frame(width: 880, height: 760, alignment: .topLeading).background(Color.white)
                .environment(\.colorScheme, .light))
            view.appearance = NSAppearance(named: .aqua)
            view.frame = CGRect(x: 0, y: 0, width: 880, height: 760)
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
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent(provider.rawValue + ".png"))
            }
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
