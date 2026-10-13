import AppKit
import Combine
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Liquid Glass intensity", .serialized, .exclusiveUIState)
@MainActor
struct LiquidGlassIntensityTests {
    @Test func `stored intensity is bounded and survives style changes`() throws {
        let defaults = try #require(UserDefaults(suiteName: "glass-intensity-" + UUID().uuidString))
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.liquidGlassIntensity == LiquidGlassIntensity.defaultValue)
        settings.liquidGlassIntensity = 0.8
        settings.interfaceStyle = .classic
        #expect(SettingsStore(defaults: defaults).liquidGlassIntensity == 0.8)
        settings.interfaceStyle = .liquidGlass
        #expect(settings.liquidGlassIntensity == 0.8)
        for (input, expected) in [
            (Double(-1), 0.0),
            (2.0, 1.0),
            (.nan, LiquidGlassIntensity.defaultValue),
            (.infinity, LiquidGlassIntensity.defaultValue)
        ] {
            settings.liquidGlassIntensity = input
            #expect(settings.liquidGlassIntensity == expected)
        }
        defaults.set("invalid", forKey: "ui.liquidGlassIntensity")
        #expect(settings.liquidGlassIntensity == LiquidGlassIntensity.defaultValue)
        defaults.set(-4.0, forKey: "ui.liquidGlassIntensity")
        #expect(settings.liquidGlassIntensity == 0)
    }

    @Test func `density is continuous and keeps the existing midpoint`() {
        for base in [0.06, 0.18, 0.22, 0.68, 0.92] {
            #expect(LiquidGlassIntensity(0.5).nativeFrostOpacity(base) == base)
            #expect(LiquidGlassIntensity(0.5).backdropOpacity(base) == base)
            #expect(LiquidGlassIntensity(0.5).legacyFrostOpacity(base) == base)
            var previous = -1.0
            for step in 0 ... 100 {
                let intensity = LiquidGlassIntensity(Double(step) / 100)
                let density = intensity.backdropOpacity(base)
                #expect(density >= previous && density <= 1)
                previous = density
            }
            #expect(LiquidGlassIntensity(1).backdropOpacity(base) > LiquidGlassIntensity(0).backdropOpacity(base))
            #expect(LiquidGlassIntensity(0).legacyFrostOpacity(base) >= base * 0.8)
        }
        #expect(LiquidGlassIntensity(0.5 - 0.00001).extraTintOpacity == 0)
        #expect(LiquidGlassIntensity(0.5 + 0.00001).extraTintOpacity < 0.0001)
    }

    @Test func `existing roots and detached menus follow changes from another store`() async throws {
        _ = NSApplication.shared
        let defaults = try #require(UserDefaults(suiteName: "glass-live-" + UUID().uuidString))
        let settings = SettingsStore(defaults: defaults)
        let observer = InterfaceStyleObserver(settings: settings)
        let holder = AskHoverAnchor.Holder()
        let parent = NSHostingView(rootView: AskHoverAnchor(holder: holder).interfaceStyle(following: observer))
        parent.frame = .init(x: 0, y: 0, width: 20, height: 20)
        parent.layoutSubtreeIfNeeded()
        let anchor = try #require(holder.view)
        var seen: [Double] = []
        let child = NSHostingView(rootView: AskHoverAnchor.styled(IntensityProbe { seen.append($0) }, of: anchor))
        child.frame = parent.frame
        child.layoutSubtreeIfNeeded()
        #expect(seen.last == LiquidGlassIntensity.defaultValue)
        var updates = 0
        let subscription = observer.objectWillChange.sink { updates += 1 }
        let otherStore = SettingsStore(defaults: defaults)
        otherStore.liquidGlassIntensity = 0.8
        otherStore.liquidGlassIntensity = 0.8
        for _ in 0 ..< 50 where seen.last != 0.8 {
            parent.layoutSubtreeIfNeeded()
            child.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observer.style == .liquidGlass)
        #expect(updates == 1)
        #expect(seen.last == 0.8)
        #expect(AskHoverAnchor.intensity(of: anchor).value == 0.8)
        subscription.cancel()
    }

    @Test func `settings persist the slider value`() throws {
        let defaults = try #require(UserDefaults(suiteName: "glass-settings-" + UUID().uuidString))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(defaults: defaults)
        let model = StudioViewModel(settingsStore: settings, historyStore: SQLiteHistoryStore(baseDir: root),
                                    initialSection: .settings,
                                    modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false))
        #expect(model.liquidGlassIntensity == LiquidGlassIntensity.defaultValue)
        model.setLiquidGlassIntensity(0.2)
        #expect(model.liquidGlassIntensity == 0.2)
        #expect(SettingsStore(defaults: defaults).liquidGlassIntensity == 0.2)
        model.setInterfaceStyle(.classic)
        model.setInterfaceStyle(.liquidGlass)
        #expect(model.liquidGlassIntensity == 0.2)
    }

    @Test func `preview fits narrow settings and renders all densities`() async throws {
        _ = NSApplication.shared
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        for dark in [false, true] {
            for value in [0.0, 0.5, 1.0] {
                let view = LiquidGlassIntensitySetting(value: .constant(value))
                    .padding(20).frame(width: 340)
                    .background(TypefluxColor.controlBackground.color)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 340, height: 340),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.center()
                window.orderFront(nil)
                defer { window.orderOut(nil); window.close() }
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.width <= 340)
                #expect(host.fittingSize.height <= 340)
                if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_GLASS_INTENSITY_SNAPSHOTS"] {
                    let root = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let file = root
                        .appendingPathComponent("intensity-\(dark ? "dark" : "light")-\(Int(value * 100)).png")
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
                    try capture.run()
                    capture.waitUntilExit()
                    #expect(capture.terminationStatus == 0)
                }
            }
        }
    }

    @Test func `settings hide the slider in classic and restore its value`() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let language = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(language) }
        let defaults = try #require(UserDefaults(suiteName: "glass-settings-ui-" + UUID().uuidString))
        let settings = SettingsStore(defaults: defaults)
        settings.appLanguage = .simplifiedChinese
        settings.liquidGlassIntensity = 0.8
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StudioViewModel(settingsStore: settings, historyStore: SQLiteHistoryStore(baseDir: root),
                                    initialSection: .settings,
                                    modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false))
        let host = NSHostingView(rootView: StudioView(viewModel: model, settingsPane: .appearance))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1060, height: 860),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.center()
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        for style in [InterfaceStyle.liquidGlass, .classic, .liquidGlass] {
            model.setInterfaceStyle(style)
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            let identifiers = accessibilityIdentifiers(host)
            #expect(identifiers.contains("settings.liquidGlassIntensity.slider") == style.usesGlass,
                    "Style \(style); identifiers: \(identifiers)")
            #expect(model.liquidGlassIntensity == 0.8)
        }
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_GLASS_INTENSITY_SNAPSHOTS"] {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: directory),
                withIntermediateDirectories: true
            )
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                                 URL(fileURLWithPath: directory).appendingPathComponent("settings-intensity.png").path]
            try capture.run()
            capture.waitUntilExit()
            #expect(capture.terminationStatus == 0)
        }
    }

    private func accessibilityIdentifiers(_ root: NSObject) -> [String] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ object: NSObject) -> [String] {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let identifier = object.responds(to: NSSelectorFromString("accessibilityIdentifier"))
                ? object.value(forKey: "accessibilityIdentifier") as? String : nil
            let children = object.responds(to: NSSelectorFromString("accessibilityChildren"))
                ? object.value(forKey: "accessibilityChildren") as? [NSObject] ?? [] : []
            return (identifier.map { [$0] } ?? []) + children.flatMap(walk)
        }
        return walk(root)
    }
}

private struct IntensityProbe: View {
    @Environment(\.liquidGlassIntensity) private var intensity
    var report: (Double) -> Void
    var body: some View {
        Color.clear.onAppear { report(intensity.value) }.onChange(of: intensity) { report($0.value) }
    }
}
