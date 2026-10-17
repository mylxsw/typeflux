import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct AppearanceSettingsTests {
    private typealias UI = SettingsBehaviorTestSupport

    private func withModel(_ check: (SettingsStore, StudioViewModel) async throws -> Void) async throws {
        try await UI.withFixture { settings in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = StudioViewModel(settingsStore: settings, historyStore: SQLiteHistoryStore(baseDir: root),
                                        initialSection: .settings,
                                        modelLibrary: AskModelLibrary(
                                            defaults: settings.defaults,
                                            automaticallyLoadsCatalog: false
                                        ))
            try await check(settings, model)
        }
    }

    @Test func `settings navigation separates appearance from general and launcher`() async throws {
        try await withModel { settings, model in
            for width in [720.0, 1100.0, 1280.0] {
                try await UI.withWindow(StudioView(viewModel: model), width: width, height: 1000) { _, host in
                    try await UI.wait { UI.contains(L("settings.launchAtLogin.title"), in: host) }
                    #expect(!UI.contains(L("settings.interfaceStyle.title"), in: host))
                    let general = try UI.button(AppSettingsPane.general.title, in: host)
                    let appearance = try UI.button(AppSettingsPane.appearance.title, in: host)
                    #expect(abs(general.frame.midY - appearance.frame.midY) < 1)
                    #expect(appearance.frame.minX > general.frame.maxX)
                    let launchLabel = try #require(UI.elements(in: host).first {
                        $0.text == L("settings.launchAtLogin.title")
                    })
                    #expect(launchLabel.frame.minX - general.frame.minX < SettingsPaneMetrics.listWidth)
                    try UI.snapshot(host, name: "settings-tabs-general-\(Int(width))")
                    try appearance.press()
                    try await UI.wait { UI.contains(L("settings.interfaceStyle.title"), in: host) }
                    #expect(!UI.contains(L("settings.launchAtLogin.title"), in: host))
                    #expect(UI.contains(L("ask.settings.windowMode.title"), in: host))
                    try UI.snapshot(host, name: "settings-tabs-appearance-\(Int(width))")
                    try UI.button(AppSettingsPane.general.title, in: host).press()
                    try await UI.wait { UI.contains(L("settings.launchAtLogin.title"), in: host) }
                }
            }
            try await UI.withWindow(LauncherSettingsView(settings: settings)) { _, host in
                #expect(!UI.contains(L("ask.settings.windowMode.title"), in: host))
                #expect(UI.contains(L("ask.settings.quick.calculator.title"), in: host))
            }
        }
    }

    @Test func `rendered choices persist and restore the hidden glass value`() async throws {
        try await withModel { settings, model in
            model.setLiquidGlassIntensity(0.82)
            try await UI.withWindow(AppearanceSettingsView(viewModel: model), width: 574, height: 1000) { _, host in
                for style in AppIconStyle.allCases {
                    #expect(AppIconController.image(for: style) != nil)
                    try UI.button(style.displayName, in: host).press()
                    #expect(settings.appIconStyle == style)
                    #expect(model.appIconStyle == style)
                }
                for appearance in AppearanceMode.allCases {
                    try UI.button(appearance.displayName, in: host).press()
                    #expect(settings.appearanceMode == appearance)
                    #expect(model.appearanceMode == appearance)
                }
                for style in [InterfaceStyle.classic, .liquidGlass] {
                    try UI.button(style.displayName, in: host).press()
                    try await UI.wait { hasSlider(host) == style.usesGlass }
                    #expect(settings.interfaceStyle == style)
                    #expect(model.liquidGlassIntensity == 0.82)
                }
                for mode in AskLauncherWindowMode.allCases {
                    try UI.button(mode.title, in: host).press()
                    #expect(settings.askLauncherWindowMode == mode)
                    #expect(model.launcherWindowMode == mode)
                }
                model.setAppLanguage(.simplifiedChinese)
                try await UI.wait { UI.contains("界面语言", in: host) }
                #expect(settings.appLanguage == .simplifiedChinese)
                #expect(!UI.contains(L("settings.appearance.subtitle"), in: host))
                #expect(!UI.contains(L("settings.glassIntensity.subtitle"), in: host))
            }
            let restored = SettingsStore(defaults: settings.defaults)
            #expect(restored.liquidGlassIntensity == 0.82)
            #expect(restored.askLauncherWindowMode == model.launcherWindowMode)
            #expect(restored.appLanguage == model.appLanguage)
            #expect(restored.appearanceMode == model.appearanceMode)
            #expect(restored.appIconStyle == model.appIconStyle)
        }
    }

    @Test func `legacy defaults load without a migration`() async throws {
        try await withModel { settings, _ in
            settings.defaults.set("simple", forKey: "ask.launcher.windowMode")
            settings.defaults.set("dark", forKey: "ui.appearance")
            settings.defaults.set("classic", forKey: "ui.overlayStyle")
            settings.defaults.set(0.36, forKey: "ui.liquidGlassIntensity")
            settings.defaults.set("ja", forKey: "ui.language")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = StudioViewModel(settingsStore: settings, historyStore: SQLiteHistoryStore(baseDir: root),
                                        initialSection: .settings,
                                        modelLibrary: AskModelLibrary(
                                            defaults: settings.defaults,
                                            automaticallyLoadsCatalog: false
                                        ))
            #expect(model.launcherWindowMode == .simple)
            #expect(model.appearanceMode == .dark)
            #expect(model.interfaceStyle == .classic)
            #expect(model.liquidGlassIntensity == 0.36)
            #expect(model.appLanguage == .japanese)
        }
    }

    @Test func `accessibility restrictions disable glass adjustment and explain why`() async throws {
        try await withModel { _, model in
            for restricted in [false, true] {
                let view = LiquidGlassIntensityControl(
                    value: Binding(get: { model.liquidGlassIntensity }, set: model.setLiquidGlassIntensity),
                    accessibilityOverride: restricted
                )
                try await UI.withWindow(view, width: 574, height: 1000) { _, host in
                    let slider = try #require(UI.elements(in: host).first {
                        $0.value("accessibilityIdentifier") as? String == "settings.liquidGlassIntensity.slider"
                    })
                    #expect(slider.value("isAccessibilityEnabled") as? Bool == !restricted)
                    #expect(UI.contains(L("settings.glassIntensity.accessibility"), in: host) == restricted)
                }
            }
        }
    }

    @Test func `all languages fit narrow and wide appearance panes in both themes`() async throws {
        try await withModel { _, model in
            for language in AppLanguage.allCases {
                model.setAppLanguage(language)
                for width in [340.0, 574.0] {
                    for dark in [false, true] {
                        let view = AppearanceSettingsView(viewModel: model)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .background(StudioTheme.windowBackground)
                        try await UI.withWindow(view, width: width, height: 1000) { window, host in
                            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                            try await Task.sleep(for: .milliseconds(80))
                            host.layoutSubtreeIfNeeded()
                            let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                            let labels = [AppearanceMode.system.displayName, InterfaceStyle.classic.displayName,
                                          AskLauncherWindowMode.simple.title, AskLauncherWindowMode.complete.title]
                                + AppIconStyle.allCases.map(\.displayName)
                            for label in labels {
                                let button = try UI.button(label, in: host)
                                #expect(button.frame.width > 0)
                                #expect(button.frame.minX >= bounds.minX - 1)
                                #expect(button.frame.maxX <= bounds.maxX + 1)
                            }
                            #expect(host.fittingSize.width <= width)
                            try UI.snapshot(
                                host,
                                name: "appearance-\(language.rawValue)-\(Int(width))-\(dark ? "dark" : "light")"
                            )
                        }
                    }
                }
            }
        }
    }

    @Test func `appearance renders inside the full settings shell at minimum and default sizes`() async throws {
        try await withModel { _, model in
            model.setAppLanguage(.simplifiedChinese)
            for (width, height) in [(720.0, 500.0), (1100.0, 800.0), (1280.0, 1000.0)] {
                for dark in [false, true] {
                    model.setAppearanceMode(dark ? .dark : .light)
                    try await UI.withWindow(StudioView(viewModel: model, settingsPane: .appearance),
                                            width: width, height: height) { window, host in
                        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        try await UI.wait { hasSlider(host) }
                        try await Task.sleep(for: .milliseconds(150))
                        #expect(UI.contains(AppSettingsPane.appearance.title, in: host))
                        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_GUL329_SNAPSHOTS"] {
                            try FileManager.default.createDirectory(
                                atPath: directory,
                                withIntermediateDirectories: true
                            )
                            window.setFrameOrigin(NSPoint(x: 40, y: 40))
                            try await Task.sleep(for: .milliseconds(150))
                            let capture = Process()
                            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                                                 URL(fileURLWithPath: directory).appendingPathComponent(
                                                     "settings-appearance-\(Int(width))-\(dark ? "dark" : "light").png"
                                                 )
                                                 .path]
                            try capture.run()
                            capture.waitUntilExit()
                            #expect(capture.terminationStatus == 0)
                        }
                    }
                }
            }
        }
    }

    private func hasSlider(_ host: NSView) -> Bool {
        UI.elements(in: host).contains {
            $0.value("accessibilityIdentifier") as? String == "settings.liquidGlassIntensity.slider"
        }
    }
}
