import AppKit
import Combine
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct OnboardingTryTests {
    private typealias UI = SettingsBehaviorTestSupport

    private func withNativeWindow(_ content: some View, appearance: AppearanceMode,
                                  check: (NSWindow, NSView) async throws -> Void) async throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 960, height: 664),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: content.frame(width: 960, height: 664).ignoresSafeArea())
        host.sizingOptions = []
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = AppAppearance.nsAppearance(for: appearance)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        let frame = try #require(window.contentView?.superview)
        try await UI.wait { UI.contains(OnboardingStrings.text("title", table: "OnboardingTry"), in: frame) }
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        try await check(window, frame)
    }

    @Test func `try model initializes with default state`() async throws {
        try await UI.withFixture { settings in
            let viewModel = OnboardingViewModel(settingsStore: settings,
                                                modelLibrary: AskModelLibrary(
                                                    defaults: settings.defaults,
                                                    automaticallyLoadsCatalog: false
                                                ),
                                                globeKeyReader: OnboardingReadyGlobeKey(),
                                                localModelManager: OnboardingTestModelManager(),
                                                onComplete: {})
            let model = viewModel.tryModel

            #expect(model.selectedFeature == .voice)
            #expect(model.triedFeatures.isEmpty)
            #expect(model.canContinue == nil)
            #expect(!model.isBusy)
            #expect(model.primaryAction == nil)
            #expect(!model.isTried(.voice))
            #expect(!model.isTried(.launcher))
            #expect(!model.isTried(.ring))
            #expect(!model.isTried(.chat))
        }
    }

    @Test func `feature connectivity reflects route and skip state`() async throws {
        try await UI.withFixture { settings in
            let viewModel = OnboardingViewModel(settingsStore: settings,
                                                modelLibrary: AskModelLibrary(
                                                    defaults: settings.defaults,
                                                    automaticallyLoadsCatalog: false
                                                ),
                                                globeKeyReader: OnboardingReadyGlobeKey(),
                                                localModelManager: OnboardingTestModelManager(),
                                                onComplete: {})
            let model = viewModel.tryModel

            // Cloud route (default): voice and chat are connected
            viewModel.chooseRoute(.cloud)
            #expect(model.isConnected(.voice))
            #expect(model.isConnected(.launcher))
            #expect(model.isConnected(.ring))
            #expect(model.isConnected(.chat))

            // Launcher-only route: voice and chat are disconnected
            viewModel.chooseRoute(.launcherOnly)
            #expect(!model.isConnected(.voice))
            #expect(model.isConnected(.launcher))
            #expect(model.isConnected(.ring))
            #expect(!model.isConnected(.chat))

            // Custom route with speech skipped: voice is disconnected
            viewModel.chooseRoute(.custom)
            viewModel.speechSkipped = true
            viewModel.aiSkipped = false
            #expect(!model.isConnected(.voice))
            #expect(model.isConnected(.launcher))
            #expect(model.isConnected(.ring))

            // Apple Speech is available without a provider key.
            settings.sttProvider = .appleSpeech
            // Custom route with AI skipped: chat is disconnected
            viewModel.speechSkipped = false
            viewModel.aiSkipped = true
            #expect(model.isConnected(.voice))
            #expect(!model.isConnected(.chat))
        }
    }

    @Test func `shortcut keys read live bindings from session`() async throws {
        try await UI.withFixture { settings in
            let viewModel = OnboardingViewModel(settingsStore: settings,
                                                modelLibrary: AskModelLibrary(
                                                    defaults: settings.defaults,
                                                    automaticallyLoadsCatalog: false
                                                ),
                                                globeKeyReader: OnboardingReadyGlobeKey(),
                                                localModelManager: OnboardingTestModelManager(),
                                                onComplete: {})
            let model = viewModel.tryModel

            // Default shortcuts
            let voiceKeys = model.shortcutKeys(for: .voice)
            #expect(!voiceKeys.isEmpty)

            let launcherKeys = model.shortcutKeys(for: .launcher)
            #expect(launcherKeys == settings.askHotkey.map(HotkeyFormat.components) ?? [])

            let ringKeys = model.shortcutKeys(for: .ring)
            #expect(ringKeys == settings.actionHotkeys[.ring].map(HotkeyFormat.components) ?? [])

            let chatKeys = model.shortcutKeys(for: .chat)
            #expect(chatKeys == launcherKeys + ["↩"])

            // Custom shortcut applied
            viewModel.useExternalKeyboardShortcutReplacement(.rightCommand)
            #expect(model.shortcutKeys(for: .voice) == HotkeyFormat.components(.rightCommandActivation))
            settings.activationHotkey = nil
            #expect(model.shortcutKeys(for: .voice).isEmpty)
            settings.askHotkey = nil
            settings.actionHotkeys[.ring] = nil
            #expect(model.shortcutKeys(for: .launcher).isEmpty)
            #expect(model.shortcutKeys(for: .ring).isEmpty)
            #expect(model.shortcutKeys(for: .chat).isEmpty)
        }
    }

    @Test func `feature selection and tried state transitions`() async throws {
        try await UI.withFixture { settings in
            let viewModel = OnboardingViewModel(settingsStore: settings,
                                                modelLibrary: AskModelLibrary(
                                                    defaults: settings.defaults,
                                                    automaticallyLoadsCatalog: false
                                                ),
                                                globeKeyReader: OnboardingReadyGlobeKey(),
                                                localModelManager: OnboardingTestModelManager(),
                                                onComplete: {})
            let model = viewModel.tryModel

            #expect(!model.isTried(.launcher))
            model.selectFeature(.launcher)
            #expect(model.selectedFeature == .launcher)

            model.markTried(.launcher)
            #expect(model.isTried(.launcher))

            model.selectFeature(.ring)
            #expect(model.selectedFeature == .ring)
            model.markTried(.ring)
            #expect(model.isTried(.ring))

            model.selectFeature(.chat)
            #expect(model.selectedFeature == .chat)
            model.markTried(.chat)
            #expect(model.isTried(.chat))

            // Only history-backed dictation can mark voice as tried.
            #expect(!model.isTried(.voice))
            model.markTried(.voice)
            #expect(!model.isTried(.voice))
            #expect(viewModel.voicePracticeText.isEmpty)
            #expect(!viewModel.voicePracticeSucceeded)
            model.selectFeature(.launcher)
        }
    }

    @Test func `voice practice detection via history store marks voice tried`() async throws {
        try await UI.withFixture { settings in
            let viewModel = OnboardingViewModel(settingsStore: settings,
                                                modelLibrary: AskModelLibrary(
                                                    defaults: settings.defaults,
                                                    automaticallyLoadsCatalog: false
                                                ),
                                                globeKeyReader: OnboardingReadyGlobeKey(),
                                                localModelManager: OnboardingTestModelManager(),
                                                onComplete: {})
            let model = viewModel.tryModel

            #expect(!model.isTried(.voice))
            let history = OnboardingTestHistoryStore()
            viewModel.historyStore = history
            viewModel.currentStep = .try
            viewModel.voicePracticeBeganAt = Date().addingTimeInterval(-1)
            viewModel.voicePracticeText = "Hello"
            history.records = [HistoryRecord(date: Date(), transcriptText: "Hello", recordingStatus: .succeeded,
                                             transcriptionStatus: .succeeded, processingStatus: .succeeded,
                                             applyStatus: .failed)]
            viewModel.updateVoicePractice()
            #expect(!model.isTried(.voice))
            history.records[0].applyStatus = .succeeded
            viewModel.updateVoicePractice()
            #expect(model.isTried(.voice))
        }
    }

    @Test func `returnToRoute switches step to route`() async throws {
        try await UI.withFixture { settings in
            let viewModel = OnboardingViewModel(settingsStore: settings,
                                                modelLibrary: AskModelLibrary(
                                                    defaults: settings.defaults,
                                                    automaticallyLoadsCatalog: false
                                                ),
                                                globeKeyReader: OnboardingReadyGlobeKey(),
                                                localModelManager: OnboardingTestModelManager(),
                                                onComplete: {})

            viewModel.currentStep = .try
            viewModel.returnToRoute()
            #expect(viewModel.currentStep == .route)
        }
    }

    @Test func `localization lookup provides strings in all five languages`() {
        for lang in [AppLanguage.simplifiedChinese, .traditionalChinese, .english, .japanese, .korean] {
            let eyebrow = OnboardingStrings.text("eyebrow", table: "OnboardingTry", language: lang)
            let title = OnboardingStrings.text("title", table: "OnboardingTry", language: lang)
            let voice = OnboardingStrings.text("feature.voice", table: "OnboardingTry", language: lang)
            let launcher = OnboardingStrings.text("feature.launcher", table: "OnboardingTry", language: lang)
            let ring = OnboardingStrings.text("feature.ring", table: "OnboardingTry", language: lang)
            let chat = OnboardingStrings.text("feature.chat", table: "OnboardingTry", language: lang)
            let tried = OnboardingStrings.text("button.tried", table: "OnboardingTry", language: lang)

            #expect(!eyebrow.isEmpty && eyebrow != "eyebrow")
            #expect(!title.isEmpty && title != "title")
            #expect(!voice.isEmpty && voice != "feature.voice")
            #expect(!launcher.isEmpty && launcher != "feature.launcher")
            #expect(!ring.isEmpty && ring != "feature.ring")
            #expect(!chat.isEmpty && chat != "feature.chat")
            #expect(!tried.isEmpty && tried != "button.tried")
            for key in ["ring.practiceHint", "ring.empty"] {
                let value = OnboardingStrings.text(key, table: "OnboardingTry", language: lang)
                #expect(!value.isEmpty && value != key)
            }
        }
    }

    @Test func `try page renders and completes onboarding through finish button`() async throws {
        try await UI.withFixture { settings in
            var completed = false
            let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            let viewModel = OnboardingViewModel(
                settingsStore: settings,
                modelLibrary: library,
                globeKeyReader: OnboardingReadyGlobeKey(),
                localModelManager: OnboardingTestModelManager(),
                onComplete: { completed = true }
            )
            viewModel.currentStep = .try

            try await UI.withWindow(
                OnboardingView(viewModel: viewModel, appearanceMode: .dark),
                width: 960,
                height: 664
            ) { window, host in
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true

                // Header check
                try await UI.wait {
                    UI.contains(OnboardingStrings.text("title", table: "OnboardingTry"), in: host)
                }

                #expect(!UI.contains("Hold to simulate", in: host))
                #expect(!UI.contains("按住模拟", in: host))
                #expect(!UI.contains("Send me the new homepage design by Friday.", in: host))

                // Left feature list buttons exist
                let voiceTitle = OnboardingStrings.text("feature.voice", table: "OnboardingTry")
                let launcherTitle = OnboardingStrings.text("feature.launcher", table: "OnboardingTry")
                let ringTitle = OnboardingStrings.text("feature.ring", table: "OnboardingTry")
                let chatTitle = OnboardingStrings.text("feature.chat", table: "OnboardingTry")

                try await UI.wait {
                    UI.contains(voiceTitle, in: host)
                        && UI.contains(launcherTitle, in: host)
                        && UI.contains(ringTitle, in: host)
                        && UI.contains(chatTitle, in: host)
                }

                // Switch to launcher and try it
                try UI.button(launcherTitle, in: host).press()
                try await UI.wait { viewModel.tryModel.selectedFeature == .launcher }
                let triedButton1 = try UI.button(
                    OnboardingStrings.text("button.tried", table: "OnboardingTry"),
                    in: host
                )
                try triedButton1.press()
                try await UI.wait { viewModel.tryModel.isTried(.launcher) }

                // Switch to ring and try it
                try UI.button(ringTitle, in: host).press()
                try await UI.wait { viewModel.tryModel.selectedFeature == .ring }
                let triedButton2 = try UI.button(
                    OnboardingStrings.text("button.tried", table: "OnboardingTry"),
                    in: host
                )
                try triedButton2.press()
                try await UI.wait { viewModel.tryModel.isTried(.ring) }

                // Switch to chat and try it
                try UI.button(chatTitle, in: host).press()
                try await UI.wait { viewModel.tryModel.selectedFeature == .chat }
                let triedButton3 = try UI.button(
                    OnboardingStrings.text("button.tried", table: "OnboardingTry"),
                    in: host
                )
                try triedButton3.press()
                try await UI.wait { viewModel.tryModel.isTried(.chat) }

                // Click finish button in footer
                let finishTitle = OnboardingStrings.text("finish")
                try UI.button(finishTitle, in: host).press()

                #expect(completed)
                #expect(settings.isOnboardingCompleted)
            }
        }
    }

    @Test func `ring practice renders saved actions and pointer selection stays in onboarding`() async throws {
        try await UI.withFixture { settings in
            settings.actionHotkeys[.ring] = RingConfiguration.defaultHotkey
            var action = RingAction.feature(.translate)
            action.title = "Practice translation"
            let configuration = RingConfiguration(actions: [action, .feature(.clipboard)], style: .classic,
                                                  centerTitle: "My Ring")
            settings.ringConfiguration = configuration
            let model = OnboardingViewModel(
                settingsStore: settings,
                modelLibrary: AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false),
                globeKeyReader: OnboardingReadyGlobeKey(), localModelManager: OnboardingTestModelManager(),
                onComplete: {}
            )
            model.currentStep = .try
            model.tryModel.selectFeature(.ring)
            try await withNativeWindow(OnboardingView(viewModel: model, appearanceMode: .dark),
                                       appearance: .dark) { window, host in
                func preview(in view: NSView) -> NSView? {
                    if String(describing: type(of: view)) == "OpieMenuPreviewView" { return view }
                    return view.subviews.lazy.compactMap { preview(in: $0) }.first
                }
                try await UI.wait { preview(in: host) != nil }
                let embedded = try #require(preview(in: host))
                let drawing = try #require(embedded.subviews.first?.subviews.last)
                #expect(String(describing: type(of: drawing)) == "RadialMenuView")
                let point = drawing.convert(NSPoint(x: drawing.bounds.midX, y: drawing.bounds.midY + 100), to: nil)
                func event(_ type: NSEvent.EventType) throws -> NSEvent {
                    try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
                }
                try drawing.mouseMoved(with: event(.mouseMoved))
                try await Task.sleep(for: .milliseconds(180))
                try UI.snapshot(host, name: "try-ring-native-hover")
                try drawing.mouseDown(with: event(.leftMouseDown))
                try drawing.mouseUp(with: event(.leftMouseUp))
                try await UI.wait { model.tryModel.isTried(.ring) }
                #expect(UI.contains(action.title, in: host))
                #expect(settings.ringConfiguration == configuration)
            }
        }
    }

    @Test func `ring practice follows configured titles order and appearance`() async throws {
        try await UI.withFixture { settings in
            let session = OnboardingViewModel(
                settingsStore: settings,
                modelLibrary: AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false),
                globeKeyReader: OnboardingReadyGlobeKey(), localModelManager: OnboardingTestModelManager(),
                onComplete: {}
            )
            let configuration = RingConfiguration(actions: [.feature(.clipboard), .feature(.translate)],
                                                  style: .liquidGlass, centerTitle: "Custom")
            settings.ringConfiguration = configuration
            #expect(session.tryModel.ringConfiguration == configuration)
            #expect(!session.tryModel.isTried(.ring))
        }
    }

    @Test func `try page captures native snapshots across all states in dark and light modes`() async throws {
        for language in [AppLanguage.english, .simplifiedChinese] {
            for appearance in [AppearanceMode.dark, AppearanceMode.light] {
                let mode = "\(language.rawValue)-\(appearance.rawValue)"
                try await UI.withFixture { settings in
                    settings.actionHotkeys[.ring] = .rightCommandActivation
                    let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
                    let viewModel = OnboardingViewModel(
                        settingsStore: settings,
                        modelLibrary: library,
                        globeKeyReader: OnboardingReadyGlobeKey(),
                        localModelManager: OnboardingTestModelManager(),
                        onComplete: {}
                    )
                    viewModel.setLanguage(language)
                    viewModel.currentStep = .try

                    try await withNativeWindow(
                        OnboardingView(viewModel: viewModel, appearanceMode: appearance),
                        appearance: appearance
                    ) { window, host in
                        window.titleVisibility = .hidden
                        window.titlebarAppearsTransparent = true

                        try await Task.sleep(for: .milliseconds(100))
                        try UI.snapshot(host, name: "try-0-voice-empty-\(mode)")

                        // 1. A successful real dictation state.
                        viewModel.voicePracticeText = "Send me the new homepage design by Friday."
                        viewModel.voicePracticeSucceeded = true
                        try await Task.sleep(for: .milliseconds(100))
                        try UI.snapshot(host, name: "try-1-voice-\(mode)")

                        // 2. Launcher state
                        viewModel.tryModel.selectFeature(.launcher)
                        try await Task.sleep(for: .milliseconds(100))
                        try UI.snapshot(host, name: "try-2-launcher-\(mode)")

                        // 3. Ring state
                        viewModel.tryModel.selectFeature(.ring)
                        try await Task.sleep(for: .milliseconds(100))
                        try UI.snapshot(host, name: "try-3-ring-\(mode)")

                        // 4. Chat state
                        viewModel.tryModel.selectFeature(.chat)
                        try await Task.sleep(for: .milliseconds(100))
                        try UI.snapshot(host, name: "try-4-chat-\(mode)")

                        // 5. Unconnected state (launcher-only route)
                        viewModel.chooseRoute(.launcherOnly)
                        viewModel.currentStep = .try
                        viewModel.tryModel.selectFeature(.voice)
                        try await Task.sleep(for: .milliseconds(100))
                        try UI.snapshot(host, name: "try-5-unconnected-\(mode)")
                        viewModel.tryModel.selectFeature(.chat)
                        try await Task.sleep(for: .milliseconds(100))
                        try UI.snapshot(host, name: "try-6-chat-unconnected-\(mode)")
                        try UI.button(OnboardingStrings.text("connect.button", table: "OnboardingTry"), in: host)
                            .press()
                        try await UI.wait { viewModel.currentStep == .route }
                    }
                }
            }
        }
    }
}
