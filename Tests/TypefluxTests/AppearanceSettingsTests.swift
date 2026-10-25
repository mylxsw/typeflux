import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct AppearanceSettingsTests {
    private typealias UI = SettingsBehaviorTestSupport

    private func readyButton(_ label: String, in host: NSView) async throws -> SettingsBehaviorTestSupport.Element {
        try await UI.wait {
            host.layoutSubtreeIfNeeded()
            return UI.elements(in: host).contains { $0.role == NSAccessibility.Role.button.rawValue && $0.label == label }
        }
        return try UI.button(label, in: host)
    }

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
            try await UI.withWindow(AppearanceSettingsView(viewModel: model), width: 574, height: 2000) { _, host in
                #expect(!UI.contains(L("settings.appIcon.note"), in: host))
                let texts = UI.elements(in: host).filter { $0.role == NSAccessibility.Role.staticText.rawValue }
                let iconTitle = try #require(texts.first { $0.text == L("settings.appIcon.title") })
                let languageTitle = try #require(texts.first { $0.text == L("settings.language.title") })
                #expect(iconTitle.frame.maxY < languageTitle.frame.minY)
                for style in AppIconStyle.allCases {
                    #expect(AppIconController.image(for: style) != nil)
                    #expect(!texts.contains { $0.text == style.displayName })
                    let button = try await readyButton(style.displayName, in: host)
                    #expect(button.frame.width <= 90)
                    #expect(button.frame.height <= 90)
                    try button.press()
                    #expect(settings.appIconStyle == style)
                    #expect(model.appIconStyle == style)
                }
                for appearance in AppearanceMode.allCases {
                    try await readyButton(appearance.displayName, in: host).press()
                    #expect(settings.appearanceMode == appearance)
                    #expect(model.appearanceMode == appearance)
                }
                for style in InterfaceStyle.allCases {
                    try await readyButton(style.displayName, in: host).press()
                    try await UI.wait { hasSlider(host) == style.usesGlass }
                    #expect(settings.interfaceStyle == style)
                    #expect(model.liquidGlassIntensity == 0.82)
                }
                for mode in AskLauncherWindowMode.allCases {
                    try await readyButton(mode.title, in: host).press()
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

    @Test func `frosted glass icon is bundled with transparent corners`() throws {
        #expect(AppIconController.image(for: .glassFrosted) != nil)
        let url = try #require(Bundle.appResources.url(
            forResource: "TypefluxIconGlassFrosted", withExtension: "png", subdirectory: "AppIcons"
        ) ?? Bundle.appResources.url(forResource: "TypefluxIconGlassFrosted", withExtension: "png"))
        let bitmap = try #require(NSBitmapImageRep(data: try Data(contentsOf: url)))
        #expect(bitmap.pixelsWide == 1024)
        #expect(bitmap.pixelsHigh == 1024)
        #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0)
        #expect((bitmap.colorAt(x: 512, y: 512)?.alphaComponent ?? 0) > 0.99)
    }

    @Test func `pure white icon has white background and transparent corners`() throws {
        #expect(AppIconController.image(for: .pureWhite) != nil)
        let url = try #require(Bundle.appResources.url(
            forResource: "TypefluxIconPureWhite", withExtension: "png", subdirectory: "AppIcons"
        ) ?? Bundle.appResources.url(forResource: "TypefluxIconPureWhite", withExtension: "png"))
        let bitmap = try #require(NSBitmapImageRep(data: try Data(contentsOf: url)))
        #expect(bitmap.pixelsWide == 1024)
        #expect(bitmap.pixelsHigh == 1024)
        let pixels = try #require(bitmap.bitmapData)
        let background = 200 * bitmap.bytesPerRow + 512 * 4
        #expect(pixels[background] == 255)
        #expect(pixels[background + 1] == 255)
        #expect(pixels[background + 2] == 255)
        #expect(pixels[background + 3] == 255)
        #expect(pixels[3] == 0)
    }

    @Test func `violet infinity can be selected and restored from appearance settings`() async throws {
        let previousIcon = NSApplication.shared.applicationIconImage
        defer { NSApp.applicationIconImage = previousIcon }
        try await withModel { settings, model in
            model.setAppLanguage(.simplifiedChinese)
            try await UI.withWindow(AppearanceSettingsView(viewModel: model), width: 574, height: 1100) { _, host in
                try UI.button("紫芯无限", in: host).press()
                #expect(settings.appIconStyle == .violetInfinity)
                #expect(model.appIconStyle == .violetInfinity)
                #expect(SettingsStore(defaults: settings.defaults).appIconStyle == .violetInfinity)
                #expect(AppIconController.apply(.violetInfinity))
                #expect(NSApp.applicationIconImage != nil)
                try UI.snapshot(host, name: "appearance-violet-infinity")
                try UI.button(AppIconStyle.glassFrosted.displayName, in: host).press()
                #expect(settings.appIconStyle == .glassFrosted)
            }
        }
    }

    @Test func `illustrated icons have rounded transparent corners`() throws {
        for style in [AppIconStyle.violetInfinity, .cartoonPetrol, .cartoonCobalt, .cartoonLavender, .yarnBall, .hairyPuppet] {
            let icon = try #require(AppIconController.image(for: style))
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1024,
                pixelsHigh: 1024,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            icon.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()

            #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0)
            #expect((bitmap.colorAt(x: 512, y: 200)?.alphaComponent ?? 0) > 0.99)
            if style == .violetInfinity {
                // Outer black padding must not survive; the pale tile and violet center must remain.
                for point in [(512, 50), (50, 512), (974, 512), (512, 974), (100, 100)] {
                    #expect(bitmap.colorAt(x: point.0, y: point.1)?.alphaComponent == 0)
                }
                for point in [(512, 110), (110, 512), (914, 512), (512, 914)] {
                    let edge = try #require(bitmap.colorAt(x: point.0, y: point.1)?.usingColorSpace(.deviceRGB))
                    #expect(edge.redComponent > 0.9 && edge.greenComponent > 0.9 && edge.blueComponent > 0.9)
                    #expect(edge.alphaComponent > 0.99)
                }
                let center = try #require(bitmap.colorAt(x: 512, y: 512)?.usingColorSpace(.deviceRGB))
                #expect(center.blueComponent > 0.8)
                #expect(center.blueComponent > center.redComponent + 0.15)
                #expect(center.alphaComponent > 0.99)
            }
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
                        try await UI.withWindow(view, width: width, height: 2400) { window, host in
                            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                            try await Task.sleep(for: .milliseconds(80))
                            host.layoutSubtreeIfNeeded()
                            let labels = [AppearanceMode.system.displayName, InterfaceStyle.classic.displayName,
                                          AskLauncherWindowMode.simple.title, AskLauncherWindowMode.complete.title]
                                + AppIconStyle.allCases.map(\.displayName) + VoiceCapsuleStyle.allCases.map(\.displayName)
                            // Accessibility may still expose the pre-layout frames on macOS 27.
                            // Wait for the requested controls, not merely a nonempty AX tree.
                            try await UI.wait {
                                host.layoutSubtreeIfNeeded()
                                let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                                let elements = UI.elements(in: host)
                                return labels.allSatisfy { label in
                                    elements.contains { element in
                                        element.role == NSAccessibility.Role.button.rawValue && element.label == label &&
                                            element.frame.width > 0 && element.frame.minX >= bounds.minX - 1 &&
                                            element.frame.maxX <= bounds.maxX + 1
                                    }
                                }
                            }
                            let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
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
