import AppKit
import QuartzCore
import Testing
@testable import Typeflux

@Suite("Translation acceptance feedback", .exclusiveUIState)
@MainActor
struct AskTranslationAcceptanceTests {
    private func capture(_ windows: [NSWindow], name: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_TRANSLATION_PANEL_SNAPSHOTS"],
              ProcessInfo.processInfo.environment["TYPEFLUX_TRANSLATION_NATIVE"] == "1" else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(250))
        windows.forEach {
            #expect($0.isVisible)
            $0.contentView?.layoutSubtreeIfNeeded()
            $0.display()
            $0.contentView?.displayIfNeeded()
        }
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(180))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let bounds = windows.reduce(CGRect.null) { $0.union($1.frame) }
        let top = try #require(NSScreen.screens.first).frame.maxY
        process.arguments = ["-x", "-R",
                             "\(Int(bounds.minX)),\(Int(top - bounds.maxY)),\(Int(bounds.width)),\(Int(bounds.height))"]
        process.arguments?.append(URL(fileURLWithPath: directory).appendingPathComponent(name + ".png").path)
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")).count > 10000)
    }

    @Test func `selection honors each position and unified action opens typing without a selection`() async throws {
        _ = NSApplication.shared
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let injector = TranslationPanelInjector()
        let panel = AskTranslationPanelController(model: fixture.model)
        let coordinator = AskTranslationPanelCoordinator(model: fixture.model, controller: panel,
                                                         injector: injector, recognizer: TranslationPanelRecognizer())
        let screen = try #require(NSScreen.main).visibleFrame
        injector.snapshot.selectionBounds = CGRect(x: screen.maxX - 120, y: screen.minY + 50, width: 80, height: 20)
        let last = CGPoint(x: screen.minX + 40, y: screen.minY + 40)
        for position in AskTranslationPanelPosition.allCases {
            var settings = fixture.settings.askTranslationSettings
            settings.panelPosition = position
            fixture.settings.askTranslationSettings = settings
            fixture.defaults.set(["x": Double(last.x), "y": Double(last.y)], forKey: "ask.translation.panel.origin")
            coordinator.openSelection()
            await coordinator.waitForEntry()
            await fixture.model.waitForTranslation()
            let window = try #require(panel.presentedWindow)
            let expected = AskTranslationPanelPlacement.frame(size: window.frame.size, screen: screen,
                                                              position: position, mouse: NSEvent.mouseLocation,
                                                              last: last)
            #expect(abs(window.frame.minX - expected.minX) < 1)
            #expect(abs(window.frame.minY - expected.minY) < 1)
            #expect(fixture.model.source == .selection && fixture.model.stack.submitted)
            if position == .center {
                try await capture([window], name: "center-selected")
            }
            fixture.model.dismiss()
        }
        injector.snapshot.selectedText = nil
        var settings = fixture.settings.askTranslationSettings
        settings.keepState = .none
        fixture.settings.askTranslationSettings = settings
        let calls = fixture.ai.requests.count
        coordinator.openSelection()
        await coordinator.waitForEntry()
        let window = try #require(panel.presentedWindow)
        #expect(fixture.model.source == .input && fixture.model.text.isEmpty && fixture.ai.requests.count == calls)
        #expect(window.firstResponder is NSTextView)
        try await capture([window], name: "translate-no-selection")
        fixture.model.text = "A draft awaiting Return."
        coordinator.openSelection()
        await coordinator.waitForEntry()
        #expect(fixture.model.text == "A draft awaiting Return." && fixture.ai.requests.count == calls)
        settings.keepState = .forever
        fixture.settings.askTranslationSettings = settings
        fixture.model.dismiss()
        coordinator.openSelection()
        await coordinator.waitForEntry()
        #expect(fixture.model.source == .input && fixture.model.text == "A draft awaiting Return.")
        #expect(fixture.ai.requests.count == calls)
    }

    @Test func `resizable panel restores dimensions and updates appearance while open`() throws {
        _ = NSApplication.shared
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let panel = AskTranslationPanelController(model: fixture.model)
        fixture.model.open(source: .input, text: "A source sentence.")
        panel.present()
        let window = try #require(panel.presentedWindow)
        #expect(window.styleMask.contains(.resizable))
        #expect(try window.frame.width
            == min(AskTranslationPanelPlacement.width, #require(window.screen?.visibleFrame.width)))
        let requested = panel.windowWillResize(window, to: CGSize(width: 810, height: 460))
        window.setFrame(CGRect(origin: window.frame.origin, size: requested), display: true)
        panel.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        let storedWidth = try #require(fixture.defaults.dictionary(forKey: "ask.translation.panel.size")?["width"] as? Double)
        #expect(storedWidth == Double(requested.width))
        fixture.model.dismiss()
        panel.present()
        #expect(window.frame.width == requested.width)
        let other = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        #expect(panel.windowWillResize(other, to: .zero) == .zero)
        panel.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: other))
        let minimum = panel.windowWillResize(window, to: .zero)
        #expect(minimum.width == 520 && minimum.height == 300)
        let maximum = panel.windowWillResize(window, to: CGSize(width: 10000, height: 10000))
        #expect(maximum.height == window.screen!.visibleFrame.height * 0.8)
        fixture.settings.appearanceMode = .dark
        #expect(window.appearance?.name == .darkAqua)
        fixture.settings.appearanceMode = .light
        #expect(window.appearance?.name == .aqua)
        fixture.settings.appearanceMode = .system
        #expect(window.appearance == nil)
    }

    @Test func `launcher and panel share glass and classic in dark and light with download recovery`() async throws {
        _ = NSApplication.shared
        let language = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(language) }
        AppLocalization.shared.setLanguage(.english)
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let ask = try AskTestFixture(authenticated: false)
        defer { ask.model.resetSession() }
        let launcher = AskConversationWindowController(settings: fixture.settings, model: ask.model)
        defer { launcher.dismissLauncher() }
        let panel = AskTranslationPanelController(model: fixture.model)
        fixture.device.response = "保持好奇心，不断学习。"
        fixture.ai.response = "保持好奇，持续学习。"
        for style in InterfaceStyle.allCases {
            fixture.settings.interfaceStyle = style
            for mode in [AppearanceMode.dark, .light] {
                fixture.settings.appearanceMode = mode
                fixture.model.open(source: .input, text: "Stay curious and keep learning.")
                fixture.model.translate()
                await fixture.model.waitForTranslation()
                fixture.model.pinned = true
                panel.present()
                let window = try #require(panel.presentedWindow)
                let screen = try #require(window.screen).visibleFrame
                let gap: CGFloat = 24
                let width = min(700, (screen.width - gap - 40) / 2)
                window.setFrame(CGRect(x: screen.midX + gap / 2, y: screen.midY - window.frame.height / 2,
                                       width: width, height: window.frame.height), display: true)
                var prepared = false
                launcher.showLauncher(then: { prepared = true })
                try await ask.wait { prepared }
                let session = AskPluginSession(plugins: [fixture.model.plugin]) { AskTranslatePlugin.keywords }
                ask.model.plugins = session
                session.debounce = .zero
                ask.model.launcherDraft.text = fixture.model.text
                session.enter(AskTranslatePlugin.keywords[0])
                session.update(text: fixture.model.text, selection: nil, language: .english, runWhenPlanned: true)
                try await ask.wait { session.output?.translation?.submitted == true }
                let launcherWindow = try #require(launcher.launcherWindow)
                launcherWindow.setFrame(CGRect(x: screen.midX - gap / 2 - width, y: window.frame.minY,
                                               width: width, height: window.frame.height), display: true)
                try await Task.sleep(for: .milliseconds(250))
                try await capture([launcherWindow, window], name: style.rawValue + "-" + mode.rawValue)
                launcher.dismissLauncher()
                fixture.model.dismiss()
            }
        }
        fixture.settings.interfaceStyle = .liquidGlass
        fixture.settings.appearanceMode = .light
        fixture.model.open(source: .input, text: "Stay curious and keep learning.")
        let failure = AskTranslationFailure.presenting(AskOnDeviceTranslationError.downloadRequired,
                                                       service: .device, source: "en", target: "zh-Hans",
                                                       interface: .english)
        fixture.model.output = .init(body: "", original: fixture.model.text, meta: [], source: "On-device", actions: [],
                                     translation: .init(results: [.init(service: .device, name: "On-device Translation",
                                                                        state: .failed(failure))], source: "en",
                                                        target: "zh-Hans",
                                                        interface: .english, submitted: true, isLookup: false))
        fixture.model.pinned = true
        panel.present()
        try await capture([#require(panel.presentedWindow)], name: "download-language-pack")
        fixture.model.retryDownloadedLanguages()
        await fixture.model.waitForTranslation()
        #expect(fixture.model.stack.results.first?.completedText != nil)
        let calls = fixture.ai.requests.count
        fixture.model.retryDownloadedLanguages()
        #expect(fixture.ai.requests.count == calls)
        fixture.model.text = "A new unsubmitted draft."
        fixture.model.retryDownloadedLanguages()
        #expect(fixture.ai.requests.count == calls)
    }
}
