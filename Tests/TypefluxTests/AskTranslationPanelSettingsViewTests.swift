import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Translation panel settings UI", .exclusiveUIState)
@MainActor
struct AskTranslationPanelSettingsViewTests {
    @Test func `both appearances show panel preferences and the same three shortcuts`() async throws {
        _ = NSApplication.shared
        let savedLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(savedLanguage) }
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let size = CGSize(width: 840, height: 660)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            let view = AskTranslationPanelSettingsView(model: fixture.model.configuration)
                .padding(24).frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(StudioTheme.background).environment(\.colorScheme, name == "dark" ? .dark : .light)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: size)
            window.contentView = host
            window.setContentSize(size)
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.close() }
            try await Task.sleep(for: .milliseconds(150))
            let controls = SettingsBehaviorTestSupport.elements(in: window)
            for action in AppHotkeyAction.translation {
                let subtitle = try #require(controls.first {
                    $0.value("accessibilityIdentifier") as? String
                        == "ask.translation.shortcut." + action.rawValue + ".subtitle"
                })
                #expect(subtitle.text == L("hotkeys.action." + action.rawValue + ".subtitle"))
                #expect(subtitle.frame.height > 0)
                let button = try #require(controls.first {
                    $0.value("accessibilityIdentifier") as? String == "ask.translation.shortcut." + action.rawValue
                })
                try button.press()
                try button.press()
            }
            let mouse = try #require(controls.first {
                $0.value("accessibilityIdentifier") as? String == "ask.translation.panel.position.mouse"
            })
            try mouse.press()
            #expect(fixture.settings.askTranslationSettings.panelPosition == .mouse)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0)
            if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_TRANSLATION_PANEL_SNAPSHOTS"] {
                let root = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: root.appendingPathComponent("settings-" + name + ".png"))
                if ProcessInfo.processInfo.environment["TYPEFLUX_TRANSLATION_NATIVE"] == "1" {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    process.arguments = [
                        "-x",
                        "-o",
                        "-l",
                        String(window.windowNumber),
                        root.appendingPathComponent("native-settings-" + name + ".png").path
                    ]
                    try process.run(); process.waitUntilExit()
                    #expect(process.terminationStatus == 0)
                }
            }
        }
    }
}
