import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct ModelSettingsControlsTests {
    private typealias UI = SettingsBehaviorTestSupport

    @Test(arguments: [AppLanguage.english, .simplifiedChinese, .traditionalChinese, .japanese, .korean])
    func `models title stays above tabs in lists and provider details`(language: AppLanguage) async throws {
        try await withModel { _, model in
            model.setAppLanguage(language)
            model.setInterfaceStyle(.classic)
            model.setAppearanceMode(.dark)
            for width: CGFloat in [720, 1100] {
                for tab in ModelPageTab.allCases {
                    for detail in tab == .scenes ? [false] : [false, true] {
                        model.selectModelPageTab(tab)
                        if detail {
                            if tab == .speech {
                                model.focusModelProvider(.whisperAPI)
                                model.isShowingSpeechProviderDetail = true
                            } else {
                                model.selectedLanguageProviderID = "openAI"
                            }
                        }
                        try await UI.withWindow(StudioView(viewModel: model), width: width, height: 800) { window, host in
                            let title = try #require(UI.elements(in: host).first {
                                $0.value("accessibilityIdentifier") as? String == "studio.page.title"
                                    && UI.contains(StudioSection.models.title, in: $0.object)
                            })
                            let firstTab = try UI.button(ModelPageTab.scenes.title, in: host)
                            let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                            #expect(title.frame.minY > firstTab.frame.maxY)
                            #expect(abs(title.frame.minX - firstTab.frame.minX) < 2)
                            #expect(bounds.contains(title.frame), "The title stays inside the viewport")
                            if detail {
                                #expect(model.isShowingModelProviderDetail)
                                let back = try #require(UI.elements(in: host).first {
                                    $0.value("accessibilityIdentifier") as? String == "models.provider.back"
                                })
                                #expect(back.frame.maxY < firstTab.frame.minY)
                                #expect(bounds.contains(back.frame))
                            }
                            try UI.snapshot(host, name: "models-title-\(tab.rawValue)-\(detail)-\(language.rawValue)-\(Int(width))")
                        }
                    }
                }
            }
        }
    }

    @Test func `scene fields match settings menu height`() async throws {
        try await UI.withFixture { store in
            let library = AskModelLibrary(defaults: store.defaults, automaticallyLoadsCatalog: false)
            for disabled in [false, true] {
                let host = NSHostingView(rootView: AskModelMenu(library: library, reference: .constant("missing"),
                                                                disabled: disabled, fieldStyle: true))
                #expect(abs(host.fittingSize.height - SettingsControlMetrics.menuHeight) < 0.5)
                #expect(abs(host.fittingSize.width - 240) < 0.5)
            }
            for compact in [false, true] {
                let host = NSHostingView(rootView: AskModelMenu(
                    library: library,
                    reference: .constant("missing"),
                    compact: compact
                ))
                #expect(abs(host.fittingSize.height - (compact ? AskMetrics.composerControlHeight : 32)) < 0.5)
            }
        }
    }

    @Test func `speech menu uses whole field and persists remote and local selection`() async throws {
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
                    #expect(abs(menuButton.bounds.height - SettingsControlMetrics.menuHeight) < 1)
                    #expect(abs(menuButton.bounds.width - 240) < 1)
                    // NSView.hitTest expects coordinates in its superview, which may have a
                    // different flipped coordinate system from this SwiftUI hosting view.
                    let hostParent = try #require(host.superview)
                    let bounds = menuButton.bounds
                    for point in [NSPoint(x: 1, y: bounds.midY), NSPoint(x: bounds.maxX - 1, y: bounds.midY),
                                  NSPoint(x: bounds.midX, y: 1), NSPoint(x: bounds.midX, y: bounds.maxY - 1)] {
                        #expect(host.hitTest(hostParent.convert(point, from: menuButton)) === menuButton)
                    }
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
                    #expect(abs(host.fittingSize.height - SettingsControlMetrics.height) < 0.5)
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
            model.selectModelPageTab(.language)
            try await UI.withWindow(StudioView(viewModel: model), width: 1100, height: 800) { window, host in
                let add = try UI.button(L("models.addEndpoint"), in: host)
                let point = window.convertPoint(fromScreen: NSPoint(x: add.frame.midX, y: add.frame.midY))
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                    window.sendEvent(event)
                }
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
                model.modelSearchQuery = "fixture-no-match"
                try await UI.wait { UI.contains(String(format: L("models.searchEmpty"), "fixture-no-match"), in: host) }
                try UI.button(ModelPageTab.speech.title, in: host).press()
                try await UI.wait { model.modelPageTab == .speech }
                #expect(model.modelSearchQuery.isEmpty)
                #expect(!UI.contains(L("models.addEndpoint"), in: host))
                model.focusModelProvider(.whisperAPI)
                model.isShowingSpeechProviderDetail = true
                try await UI.wait { UI.contains(L("settings.models.transcriptionEndpoint"), in: host) }
                let speechBack = try #require(UI.elements(in: host).first {
                    $0.value("accessibilityIdentifier") as? String == "models.provider.back"
                })
                try speechBack.press()
                try await UI.wait { !model.isShowingSpeechProviderDetail }
                model.isShowingSpeechProviderDetail = true
                try UI.button(ModelPageTab.scenes.title, in: host).press()
                try await UI.wait { model.modelPageTab == .scenes }
                #expect(!model.isShowingModelProviderDetail)
            }
        }
    }

    @Test func `header actions do not overlap tabs at narrow widths`() async throws {
        try await withModel { _, model in
            model.selectModelPageTab(.language)
            for language in [AppLanguage.english, .simplifiedChinese, .japanese] {
                AppLocalization.shared.setLanguage(language)
                for width: CGFloat in [920, 1100] {
                    try await UI.withWindow(StudioView(viewModel: model), width: width, height: 800) { _, host in
                        let elements = UI.elements(in: host)
                        let tab = try #require(elements.first {
                            $0.value("accessibilityIdentifier") as? String == "studio.models.tab.language"
                        })
                        let search = try #require(elements.first {
                            $0.value("accessibilityIdentifier") as? String == "models.search"
                        })
                        let add = try #require(elements.first {
                            $0.value("accessibilityIdentifier") as? String == "models.addProvider"
                        })
                        #expect(tab.frame.width > 0)
                        #expect(search.frame.width > 0)
                        #expect(add.frame.width > 0)
                        #expect(!tab.frame.intersects(search.frame))
                        #expect(!tab.frame.intersects(add.frame))
                        #expect(!search.frame.intersects(add.frame))
                    }
                }
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
            model.selectModelPageTab(.speech)
            for provider in STTProvider.settingsDisplayOrder {
                model.focusModelProvider(provider.studioProviderID)
                model.isShowingSpeechProviderDetail = true
                try await UI.withWindow(StudioView(viewModel: model), width: 920, height: 800) { window, host in
                    let elements = UI.elements(in: host)
                    #expect(elements.contains { $0.value("accessibilityIdentifier") as? String == "models.provider.title" })
                    #expect(UI.contains(L("models.connection"), in: host))
                    #expect(UI.contains(L("models.configured"), in: host)
                        || UI.contains(L("models.notConfigured"), in: host))
                    #expect(!UI.contains(L("settings.models.focused.whisper"), in: host))
                    #expect(!UI.contains(L("settings.models.focused.googleCloud"), in: host))
                    #expect(!UI.contains(L("settings.models.focused.localSTT"), in: host))
                    var labels: [UI.Element] = []
                    for element in elements {
                        let identifier = element.value("accessibilityIdentifier") as? String ?? ""
                        if identifier.hasPrefix("models.form.label.") { labels.append(element) }
                    }
                    #expect(!labels.isEmpty)
                    for label in labels {
                        let identifier = try #require(label.value("accessibilityIdentifier") as? String)
                            .replacingOccurrences(of: "models.form.label.", with: "models.form.field.")
                        let field = try #require(elements.first {
                            $0.value("accessibilityIdentifier") as? String == identifier
                        })
                        #expect(label.frame.width > 0)
                        #expect(field.frame.width > 0)
                        #expect(label.frame.maxX <= field.frame.minX)
                        #expect(field.frame.maxX <= window.frame.maxX)
                    }
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
            model.selectModelPageTab(.speech)
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
            model.selectModelPageTab(.speech)
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
            model.selectModelPageTab(.speech)
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
