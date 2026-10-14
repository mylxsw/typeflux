import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import Typeflux

extension AskTranslationPolishTests {
    @Test func `launcher and complete settings render in both appearances`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            AppLocalization.shared.setLanguage(.simplifiedChinese)
            let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            let ask = try AskTestFixture(modelLibrary: library)
            defer { ask.model.resetSession() }
            let device = AskTestTranslationEngine(), ai = AskTestTranslationEngine(),
                provider = AskTestTranslationEngine()
            device.response = "意外发现"
            provider.response = "偶然性"
            let dictionary = AskTestWordLookup(answer: .card(card))
            let book = makeTestWordBook()
            let services = AskTranslationSettings(services: [.device, .ai(), .provider(.deepl, enabled: true),
                                                             .provider(.youdao, enabled: true)])
            let plugin = AskTranslatePlugin(onDevice: device, ai: ai, dictionary: dictionary, wordBook: book,
                                            serviceSettings: { services }, service: { _ in provider },
                                            fanout: AskTranslationFanout(), serviceName: { service in
                                                service.isAI ? "AI · Typeflux Cloud" : service.kind == .device
                                                    ? L("ask.translation.stack.deviceTitle") : service.provider!.title
                                            }, detector: AskTestLanguageDetector(language: "en"))
            let session = AskPluginSession(plugins: [plugin]) { AskTranslatePlugin.keywords }
            session.debounce = .zero
            ask.model.plugins = session
            ask.model.wordBook = AskWordBookRecorder(store: book)
            ask.model.connectWordBook(to: session)
            ask.model.launcherDraft.text = "serendipity"
            session.enter(AskTranslatePlugin.keywords[0])
            session.update(text: "serendipity", selection: nil, language: .simplifiedChinese)
            try await SettingsBehaviorTestSupport.wait { session.output != nil }
            #expect(session.run())
            try await SettingsBehaviorTestSupport.wait { session.output?.wordCard != nil && !session.isRunning }
            #expect(session.output?.actions.contains { $0.shortcut == .commandS } == true)
            #expect(session.output?.actions.contains { $0.shortcut == .commandB } == true)
            for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                settings.appearanceMode = name == "dark" ? .dark : .light
                let height = AskPluginResultsView.height(for: AskPluginDisplay(
                    title: plugin.title,
                    symbol: plugin.symbol,
                    phase: session.phase
                )) + 120
                try await capture(AskLauncherView(model: ask.model, onDismiss: {}), size: NSSize(
                    width: AskMetrics.launcherWidth, height: height
                ), appearance: appearance, name: "launcher-" + name)
                let settingsView = AskTranslationSettingsView(settings: settings, library: library,
                                                              credentials: AskTestTranslationCredentials())
                    .padding(24).background(StudioTheme.background)
                    .environment(\.colorScheme, name == "dark" ? .dark : .light)
                try await capture(settingsView, size: NSSize(width: 900, height: 1160), appearance: appearance,
                                  name: "settings-full-" + name)
                #expect(settings.askTranslationSettings.services.filter(\.enabled).map(\.id) == [
                    "device",
                    "ai.primary"
                ])
            }
        }
    }

    private func capture(_ view: some View, size: NSSize, appearance: NSAppearance.Name, name: String) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        window.contentView = host
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded(); window.display(); CATransaction.flush()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1000)
        if name.hasPrefix("settings") {
            #expect(SettingsBehaviorTestSupport.elements(in: window).contains {
                $0.value("accessibilityIdentifier") as? String == "ask.translation.service.provider.volcengine"
                    && $0.frame.height > 0 && window.frame.contains($0.frame)
            })
        }
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_TRANSLATION_PANEL_SNAPSHOTS"] {
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try png.write(to: root.appendingPathComponent(name + ".png"))
            if ProcessInfo.processInfo.environment["TYPEFLUX_TRANSLATION_NATIVE"] == "1" {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                                     root.appendingPathComponent("native-" + name + ".png").path]
                try process.run(); process.waitUntilExit()
                #expect(process.terminationStatus == 0)
            }
        }
    }
}
