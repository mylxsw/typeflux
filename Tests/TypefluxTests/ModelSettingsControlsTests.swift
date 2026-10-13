import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct ModelSettingsControlsTests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test func `model segments live in the native toolbar`() async throws {
        try await withModel { _, model in
            for width: CGFloat in [920, 1100] {
                try await UI.withWindow(StudioView(viewModel: model), width: width, height: 800) { window, _ in
                    try await UI
                        .wait {
                            window.toolbar?.items
                                .contains { $0.itemIdentifier.rawValue == "typeflux.window.segments" } == true
                        }
                    let toolbar = try #require(window.toolbar)
                    try await UI.wait {
                        !toolbar.centeredItemIdentifiers.contains(.init("typeflux.window.title"))
                            && toolbar.centeredItemIdentifiers.contains(.init("typeflux.window.segments"))
                    }
                    let item = try #require(toolbar.items
                        .first { $0.itemIdentifier.rawValue == "typeflux.window.segments" })
                    let segments = try #require(item.view
                        .flatMap { descendants($0).compactMap { $0 as? NSSegmentedControl }.first })
                    #expect(segments.segmentCount == ModelPageTab.allCases.count)
                    for (index, tab) in ModelPageTab.allCases.enumerated() {
                        segments.selectedSegment = index
                        segments.sendAction(segments.action, to: segments.target)
                        try await UI.wait { model.modelPageTab == tab }
                    }
                }
            }
        }
    }

    @Test func `native speech popup persists remote and local selection`() async throws {
        try await withModel { store, model in
            store.whisperAPIKey = "fixture"
            store.whisperBaseURL = "https://fixture.invalid/v1"
            store.whisperModel = "whisper-1"
            model.setSTTProvider(.whisperAPI)
            try await UI
                .withWindow(ModelSettingsPage(viewModel: model, library: model.modelLibrary) { EmptyView()
                }) { _, host in
                    try await Task.sleep(for: .milliseconds(100))
                    host.layoutSubtreeIfNeeded()
                    let menuButton = try #require(descendants(host).compactMap { $0 as? NSPopUpButton }.first)
                    #expect(!menuButton.isBordered)
                    #expect(menuButton.bounds.height > 0)
                    #expect(menuButton.bounds.width > 0)
                    let menu = try #require(menuButton.menu)
                    let local = try #require(menu.items
                        .firstIndex { $0.title == LocalSTTModel.senseVoiceSmall.displayName })
                    menu.performActionForItem(at: local)
                    #expect(model.sttProvider == .localModel)
                    #expect(store.sttProvider == .localModel)
                    #expect(store.localSTTModel == .senseVoiceSmall)
                    let remote = try #require(menu.items
                        .firstIndex { $0.title.hasPrefix(STTProvider.whisperAPI.displayName) })
                    menu.performActionForItem(at: remote)
                    #expect(model.sttProvider == .whisperAPI)
                    #expect(store.sttProvider == .whisperAPI)
                }
        }
    }

    @Test func `action buttons share chrome and block loading actions`() async throws {
        try await UI.withFixture { _ in
            var calls = 0
            for primary in [false, true] {
                for loading in [false, true] {
                    let action = SettingsActionButton(title: "Save fixture", symbol: "checkmark", primary: primary,
                                                      isLoading: loading) { calls += 1 }
                    let host = NSHostingView(rootView: action)
                    #expect(host.fittingSize.height > 0)
                    try await UI.withWindow(action, width: 300, height: 100) { _, host in
                        let control = try #require(UI.elements(in: host).first {
                            $0.label == "Save fixture" && $0.role == (loading ? "AXBusyIndicator" : "AXButton")
                        })
                        if !loading {
                            try control.press()
                        }
                        #expect((control.value("isAccessibilityEnabled") as? Bool) == !loading)
                    }
                }
            }
            #expect(calls == 2)
        }
    }

    @Test func `provider navigation and search remain inside their tabs`() async throws {
        try await withModel { _, model in
            model.selectModelPageTab(.providers)
            try await TypefluxNavigationTestSupport.withWindow(StudioView(viewModel: model), size: NSSize(width: 1100, height: 800)) { window, host in
                try await UI.wait { UI.contains(L("models.addEndpoint"), in: window) }
                let add = try UI.button(L("models.addEndpoint"), in: window)
                try add.press()
                try await UI.wait { window.attachedSheet != nil }
                let sheet = try #require(window.attachedSheet?.contentView)
                try UI.button(L("ask.models.cancel"), in: sheet).press()
                try await UI.wait { window.attachedSheet == nil }
                #expect(!model.isAddingModelEndpoint)
                model.selectedLanguageProviderID = "openAI"
                try await UI.wait { UI.contains("OpenAI", in: host) && !UI.contains(L("models.addEndpoint"), in: host) }
                let back = UI.elements(in: host).first {
                    $0.value("accessibilityIdentifier") as? String == "models.provider.back"
                }
                try #require(back).press()
                try await UI.wait { model.selectedLanguageProviderID == nil }
                try await UI.wait { window.toolbar?.items.contains { $0 is NSSearchToolbarItem } == true }
                model.modelSearchQuery = "fixture-no-match"
                try await UI.wait { UI.contains(String(format: L("models.searchEmpty"), "fixture-no-match"), in: host) }
                try UI.button(ModelPageTab.local.title, in: window).press()
                try await UI.wait { model.modelPageTab == .local }
                try UI.button(ModelPageTab.providers.title, in: window).press()
                try await UI.wait { model.modelPageTab == .providers }
                #expect(model.modelSearchQuery.isEmpty)
                #expect(model.modelPageTab == .providers)
                model.focusModelProvider(.whisperAPI)
                model.isShowingSpeechProviderDetail = true
                try await UI.wait { UI.contains(L("settings.models.transcriptionEndpoint"), in: host) }
                let speechBack = try #require(UI.elements(in: host).first {
                    $0.value("accessibilityIdentifier") as? String == "models.provider.back"
                })
                try speechBack.press()
                try await UI.wait { !model.isShowingSpeechProviderDetail }
                model.isShowingSpeechProviderDetail = true
                try UI.button(ModelPageTab.scenes.title, in: window).press()
                try await UI.wait { model.modelPageTab == .scenes }
                #expect(!model.isShowingModelProviderDetail)
            }
        }
    }

    @Test func `toolbar actions follow provider navigation`() async throws {
        try await withModel { _, model in
            model.selectModelPageTab(.providers)
            try await UI.withWindow(StudioView(viewModel: model), width: 1100, height: 800) { window, _ in
                try await UI
                    .wait {
                        window.toolbar?.items
                            .contains { $0.itemIdentifier.rawValue == "typeflux.window.segments" } == true
                    }
                #expect(!model.isShowingModelProviderDetail)
                model.selectedLanguageProviderID = "openAI"
                try await UI.wait { model.isShowingModelProviderDetail }
                model.selectModelPageTab(.scenes)
                try await UI.wait { !model.isShowingModelProviderDetail }
            }
        }
    }

    @Test func `section captions support counts and plain titles`() async throws {
        try await UI.withFixture { _ in
            for count: Int? in [nil, 0, 3] {
                try await UI.withWindow(
                    SettingsListSectionLabel(title: "Models", count: count),
                    width: 300,
                    height: 80
                ) { _, host in
                    #expect(UI.contains("Models", in: host))
                    if let count {
                        #expect(UI.contains(L("settings.list.itemCount", count), in: host))
                    }
                }
            }
        }
    }

    @Test func `speech details share the language provider header and form grid`() async throws {
        try await withModel { _, model in
            model.selectModelPageTab(.providers)
            for provider in STTProvider.settingsDisplayOrder {
                model.focusModelProvider(provider.studioProviderID)
                model.isShowingSpeechProviderDetail = true
                try await UI.withWindow(StudioView(viewModel: model), width: 920, height: 800) { _, host in
                    let elements = UI.elements(in: host)
                    #expect(elements
                        .contains { $0.value("accessibilityIdentifier") as? String == "models.provider.title" })
                    #expect(UI.contains(L("models.connection"), in: host))
                    #expect(UI.contains(L("models.configured"), in: host)
                        || UI.contains(L("models.notConfigured"), in: host))
                    #expect(!UI.contains(L("settings.models.focused.whisper"), in: host))
                    #expect(!UI.contains(L("settings.models.focused.googleCloud"), in: host))
                    #expect(!UI.contains(L("settings.models.focused.localSTT"), in: host))
                    #expect(elements
                        .contains {
                            ($0.value("accessibilityIdentifier") as? String ?? "").hasPrefix("models.form.row.")
                        })
                    let back = try #require(elements.first {
                        $0.value("accessibilityIdentifier") as? String == "models.provider.back"
                    })
                    try back.press()
                    try await UI.wait { !model.isShowingSpeechProviderDetail }
                }
            }
        }
    }

    @Test func `speech connection footer saves drafts and preserves test feedback`() async throws {
        try await withModel { store, model in
            model.selectModelPageTab(.providers)
            model.focusModelProvider(.whisperAPI)
            model.isShowingSpeechProviderDetail = true
            try await UI.withWindow(StudioView(viewModel: model), width: 1100, height: 800) { _, host in
                #expect(UI.contains(L("models.notConfigured"), in: host))
                model.setWhisperBaseURL("https://fixture.invalid/v1/audio/transcriptions")
                model.setWhisperModel("whisper-1")
                model.setWhisperAPIKey("fixture")
                try UI.button(L("ask.models.save"), in: host).press()
                #expect(store.whisperAPIKey == "fixture")
                #expect(store.whisperModel == "whisper-1")
                #expect(store.whisperBaseURL == "https://fixture.invalid/v1/audio/transcriptions")
                try await UI.wait { UI.contains(L("models.configured"), in: host) }
                #expect(!UI.contains(L("common.test"), in: host))
                model.sttConnectionTestState = .testing
                try await UI.wait {
                    UI.elements(in: host).contains { $0.label == L("ask.models.test") && $0.role == "AXBusyIndicator" }
                }
                let testing = try #require(UI.elements(in: host).first {
                    $0.label == L("ask.models.test") && $0.role == "AXBusyIndicator"
                })
                #expect(testing.value("isAccessibilityEnabled") as? Bool == false)
                model.sttConnectionTestState = .notice(message: "Fixture connection feedback")
                try await UI.wait { UI.contains("Fixture connection feedback", in: host) }
                #expect(try UI.button(L("ask.models.test"), in: host).value("isAccessibilityEnabled") as? Bool == true)
            }
        }
    }

    @Test func `google connection row disconnects stored authorization`() async throws {
        try await withModel(googleAuthorized: true) { _, model in
            model.selectModelPageTab(.providers)
            model.focusModelProvider(.googleCloud)
            model.isShowingSpeechProviderDetail = true
            try await UI.withWindow(StudioView(viewModel: model), width: 920, height: 800) { _, host in
                #expect(model.googleCloudOAuthAuthorized)
                #expect(UI.contains(L("settings.models.googleCloud.oauth.reauthorize"), in: host))
                try UI.button(L("settings.models.googleCloud.oauth.disconnect"), in: host).press()
                try await UI.wait { !model.googleCloudOAuthAuthorized }
                #expect(!GoogleCloudSpeechCredentialResolver.isStoredAuthorizationAvailable())
                try await UI.wait { UI.contains(L("settings.models.googleCloud.oauth.authorize"), in: host) }
            }
        }
    }

    @Test func `local model rows retain download confirmation and cancellation`() async throws {
        try await withModel { _, model in
            model.selectModelPageTab(.providers)
            model.selectModelPageTab(.local)
            model.focusModelProvider(.localSTT)
            model.focusLocalSTTModel(.funASR)
            model.localSTTTransferDetail = "Fixture transfer: 12 MB / 100 MB"
            model.isShowingSpeechProviderDetail = true
            try await UI.withWindow(StudioView(viewModel: model), width: 1100, height: 800) { window, host in
                #expect(UI.contains(L("models.configured"), in: host))
                #expect(UI.contains(L("settings.models.storagePath"), in: host))
                #expect(!UI.contains(L("ask.models.save"), in: host))
                #expect(UI.contains("Fixture transfer: 12 MB / 100 MB", in: host))
                for local in LocalSTTModel.displayOrder {
                    #expect(UI.contains(local.displayName, in: host))
                }
                try UI.button(L("settings.models.prepareLocalModel"), in: host).press()
                try await UI.wait { window.attachedSheet != nil }
                let sheet = try #require(window.attachedSheet?.contentView)
                try UI.button(L("common.cancel"), in: sheet).press()
                try await UI.wait { window.attachedSheet == nil }
                #expect(!model.isPreparingLocalSTT)
            }
        }
    }

    private func withModel(googleAuthorized: Bool = false,
                           _ check: (SettingsStore, StudioViewModel) async throws -> Void) async throws {
        try await UI.withFixture { store in
            let previousGoogleToken = GoogleCloudSpeechOAuthTokenStore.load()
            defer {
                if let previousGoogleToken {
                    GoogleCloudSpeechOAuthTokenStore.save(previousGoogleToken)
                } else {
                    GoogleCloudSpeechOAuthTokenStore.clear()
                }
            }
            if googleAuthorized {
                GoogleCloudSpeechOAuthTokenStore.save(GoogleCloudSpeechOAuthToken(
                    accessToken: "fixture-google-token", refreshToken: nil,
                    expiresAt: Int(Date().timeIntervalSince1970) + 3600
                ))
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-controls-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let model = StudioViewModel(settingsStore: store, historyStore: FileHistoryStore(baseDir: root),
                                        initialSection: .models, localModelManager: FixtureLocalModels(),
                                        modelLibrary: AskModelLibrary(
                                            defaults: store.defaults,
                                            automaticallyLoadsCatalog: false
                                        ))
            try await check(store, model)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

final class FixtureLocalModels: LocalSTTModelManaging {
    func prepareModel(settingsStore _: SettingsStore,
                      onUpdate _: (@Sendable (LocalSTTPreparationUpdate) -> Void)?) async throws {}
    func preparedModelInfo(settingsStore: SettingsStore) -> LocalSTTPreparedModelInfo? {
        guard isModelAvailable(settingsStore.localSTTModel) else { return nil }
        return LocalSTTPreparedModelInfo(storagePath: "/fixture/local-model", sourceDisplayName: "Fixture")
    }

    func isModelAvailable(_ model: LocalSTTModel) -> Bool {
        model == .senseVoiceSmall
    }

    func deleteModelFiles(_: LocalSTTModel) throws {}
    func storagePath(for _: LocalSTTConfiguration) -> String {
        "/fixture/local-model"
    }
}
