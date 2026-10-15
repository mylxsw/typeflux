import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Shared Liquid Glass surfaces", .serialized, .exclusiveUIState)
@MainActor
struct LiquidGlassSurfaceTests {
    @Test func `launcher diffusion stays scoped and accessibility removes every effect`() async throws {
        #if compiler(>=6.2)
            guard #available(macOS 26.0, *) else { return }
            for dark in [false, true] {
                for material in [AskGlassMaterial.liquidGlass, .visualEffect, .opaque] {
                    let view = AskComposerChrome.launcher.glassBackground(material)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let window = makeWindow(view, dark: dark, size: .init(width: 320, height: 160))
                    defer { window.orderOut(nil); window.close() }
                    try await Task.sleep(for: .milliseconds(100))
                    let layers = try descendants(#require(window.contentView))
                    let blur = layers.compactMap { $0 as? NSVisualEffectView }
                    let native = layers.compactMap { $0 as? NSGlassEffectView }
                    if material == .opaque {
                        #expect(blur.isEmpty && native.isEmpty)
                    } else {
                        #expect(blur.contains { $0.material == .hudWindow && $0.blendingMode == .behindWindow })
                        #expect(native.count == (material == .liquidGlass ? 1 : 0))
                    }
                }
            }
            #expect(!AskComposerChrome.workspace.glassBackground(.liquidGlass).diffuseLauncher)
        #endif
    }

    @Test func composerShadowPreservesTheBackdropUnderGlass() async throws {
        let backdrop = Color(red: 0.1, green: 0.3, blue: 0.7)
        let baseline = makeWindow(backdrop, dark: false, size: .init(width: 160, height: 100))
        defer { baseline.orderOut(nil); baseline.close() }
        try await Task.sleep(for: .milliseconds(100))
        // Compare rendered colours so the display profile and bitmap colour
        // conversion do not masquerade as a change to the shadow's backplate.
        let expected = try centerColor(baseline)
        for material in [AskGlassMaterial.liquidGlass, .visualEffect, .opaque] {
            let view = Color.clear
                .modifier(AskWorkspaceCardDepth(enabled: true, corner: 16, material: material))
                .background(backdrop)
                .environment(\.colorScheme, .light)
            let window = makeWindow(view, dark: false, size: .init(width: 160, height: 100))
            defer { window.orderOut(nil); window.close() }
            try await Task.sleep(for: .milliseconds(100))
            let center = try centerColor(window)
            if material == .opaque {
                #expect(center.redComponent > 0.98 && center.greenComponent > 0.98)
            } else {
                #expect(abs(center.redComponent - expected.redComponent) < 0.01)
                #expect(abs(center.greenComponent - expected.greenComponent) < 0.01)
                #expect(abs(center.blueComponent - expected.blueComponent) < 0.01)
            }
        }
    }

    @Test func navigationAndComposerUseRegularGlassInBothAppearances() async throws {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *) else { return }
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        for dark in [false, true] {
            for mode in ["glass", "classic", "reduced", "contrast"] {
                let view = VStack {
                    Text("Navigation").frame(width: 200, height: 80)
                        .askSidePanel(edge: .leading)
                    Text("Title controls").frame(width: 180, height: 38)
                        .askInWindowGlassPill(height: 38)
                    AskComposer(model: fixture.model, launcher: false)
                    SystemMonitorWindowBackground().frame(width: 180, height: 40)
                }
                .environment(\.interfaceStyle, mode == "classic" ? .classic : .liquidGlass)
                .environment(\.colorScheme, dark ? .dark : .light)
                // Accessibility signals are read-only SwiftUI environment values.
                // Pin the shared resolver's result instead of changing global OS settings.
                .environment(\.askGlassMaterialOverride, AskGlassBackground.effectiveMaterial(
                    .liquidGlass, reduceTransparency: mode == "reduced", increasedContrast: mode == "contrast"
                ))
                let window = makeWindow(view, dark: dark, size: .init(width: 760, height: 300),
                                        highContrast: mode == "contrast")
                defer { window.orderOut(nil); window.close() }
                try await Task.sleep(for: .milliseconds(100))
                let glass = descendants(window.contentView!).compactMap { $0 as? NSGlassEffectView }
                let edgeBackdrops = descendants(window.contentView!).compactMap { $0 as? NSVisualEffectView }
                    .filter { $0.material == .sidebar }
                if mode == "glass" {
                    #expect(glass.count == 3, "Title controls, composer and monitor must all use native glass")
                    #expect(glass.allSatisfy { $0.style == .regular })
                    #expect(edgeBackdrops.count == 1, "The flush navigation column frosts the desktop itself")
                    #expect(edgeBackdrops.allSatisfy { $0.blendingMode == .behindWindow })
                } else {
                    #expect(glass.isEmpty, "\(mode), dark=\(dark): must avoid translucent layers")
                    #expect(edgeBackdrops.isEmpty, "Classic and accessibility fallbacks must not retain a desktop blur")
                }
            }
        }
        #endif
    }

    /// Window Server captures include the refraction omitted by bitmap caching.
    /// Opt-in only; uses synthetic data and requires local screen-capture access.
    @Test func writeNativeGlassReviewWhenRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_NATIVE_GLASS_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let clipboard = ClipboardPanelModel()
        clipboard.reset(entries: [ClipboardTestSupport.entry(.text, text: "Meeting notes", sourceAppName: "Notes"),
                                  ClipboardTestSupport.entry(.link, text: "https://example.com")])
        for dark in [false, true] {
            let view = HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Typeflux").font(.title2.bold())
                    Label("Conversations", systemImage: "bubble.left.and.bubble.right")
                    Label("Workflows", systemImage: "square.stack.3d.up")
                    Label("Settings", systemImage: "gearshape")
                    Spacer()
                }
                .padding(20).frame(width: 200, height: 420)
                .askSidePanel(edge: .leading)
                VStack(spacing: 20) {
                    HStack {
                        Label("New conversation", systemImage: "square.and.pencil")
                            .padding(.horizontal, 14).frame(height: 38)
                            .askInWindowGlassPill(height: 38)
                        Spacer()
                        StudioButton(title: "Settings", systemImage: nil, variant: .secondary, action: {})
                    }
                    AskComposer(model: fixture.model, launcher: false)
                        .frame(height: 140)
                    HStack {
                        AskGlassCardSurface(kind: .menu) {
                            VStack(spacing: 2) {
                                AskPopoverRow(title: "MiniMax M3", caption: "205K context", selected: true, action: {})
                                AskPopoverRow(title: "DeepSeek Pro", caption: "205K context", selected: false, action: {})
                            }.padding(.vertical, 6)
                        }.frame(width: 300, height: 130)
                        Spacer()
                    }
                    Spacer()
                }.frame(width: ClipboardPanelView.width)
            }
            .padding(28)
            .frame(width: 1060, height: 570, alignment: .topLeading)
            .foregroundStyle(StudioTheme.textPrimary)
            .background {
                LinearGradient(colors: dark
                    ? [Color(red: 0.12, green: 0.16, blue: 0.28), Color(red: 0.32, green: 0.16, blue: 0.28)]
                    : [Color(red: 0.72, green: 0.87, blue: 0.98), Color(red: 0.99, green: 0.81, blue: 0.73)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .environment(\.interfaceStyle, .liquidGlass)
            .environment(\.colorScheme, dark ? .dark : .light)
            let window = makeWindow(view, dark: dark, size: .init(width: 1060, height: 570))
            defer { window.orderOut(nil); window.close() }
            try await Task.sleep(for: .milliseconds(500))
            try capture(window, to: root.appendingPathComponent("native-glass-\(dark ? "dark" : "light").png"))

            let clipboardView = ClipboardPanelView(model: clipboard, focusRequest: 0)
                .padding(20)
                .background(LinearGradient(colors: dark ? [.indigo, .black] : [.cyan.opacity(0.4), .orange.opacity(0.3)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                .environment(\.colorScheme, dark ? .dark : .light)
            let clipboardWindow = makeWindow(clipboardView, dark: dark, size: .init(width: 680, height: 600))
            defer { clipboardWindow.orderOut(nil); clipboardWindow.close() }
            try await Task.sleep(for: .milliseconds(500))
            try capture(clipboardWindow, to: root.appendingPathComponent("native-clipboard-\(dark ? "dark" : "light").png"))
        }
    }

    private func makeWindow(_ view: some View, dark: Bool, size: NSSize, highContrast: Bool = false) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: highContrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua))
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.center()
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    /// A separate source window catches stacked scrims that same-window
    /// gradients cannot reveal. Screen-region capture includes the compositor's
    /// behind-window sampling; window-only capture excludes those source pixels.
    @Test func writeExternalBackdropReviewWhenRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_EXTERNAL_GLASS_SNAPSHOTS"] else { return }
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        for (index, title) in ["帮我整理今天的会议记录", "翻译我选中的文字", "讲讲这一屏在做什么"].enumerated() {
            await fixture.api.seed(.init(id: "glass-\(index)", title: title, revision: 1,
                                        updatedAt: Date().addingTimeInterval(Double(-index * 3600)), messages: []))
        }
        await fixture.model.refreshHistory()
        // An open conversation shows the sidebar's selected row.
        await fixture.model.select("glass-0")
        for dark in [false, true] {
            let source = HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 26) {
                    Text("BACKGROUND WINDOW").font(.title.bold())
                    ForEach(0..<8) { i in
                        HStack {
                            RoundedRectangle(cornerRadius: 12).fill([Color.blue, .cyan, .purple, .orange][i % 4])
                                .frame(width: 84, height: 60)
                            Text("Source content \(i + 1)").font(.title2)
                        }
                    }
                    Spacer()
                }.padding(30).frame(maxWidth: .infinity).foregroundStyle(.white).background(Color(white: 0.08))
                VStack(spacing: 30) {
                    Text("BRIGHT BACKGROUND").font(.title.bold())
                    ForEach(0..<5) { i in
                        HStack(spacing: 30) {
                            RoundedRectangle(cornerRadius: 20).fill([Color.blue, .cyan, .purple][i % 3])
                            RoundedRectangle(cornerRadius: 20).fill([Color.cyan, .purple, .blue][i % 3])
                        }.frame(height: 110)
                    }
                    Spacer()
                }.padding(40).frame(maxWidth: .infinity).foregroundStyle(.black).background(Color.white)
            }
            let back = makeWindow(source, dark: false, size: .init(width: 1260, height: 860))
            back.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            back.orderFront(nil)
            defer { back.orderOut(nil); back.close() }
            let workspace = AskConversationView(model: fixture.model)
                .environment(\.interfaceStyle, .liquidGlass)
                .environment(\.colorScheme, dark ? .dark : .light)
            let main = makeWindow(workspace, dark: dark, size: .init(width: 1100, height: 740))
            main.level = NSWindow.Level(rawValue: back.level.rawValue + 1)
            main.orderFront(nil)
            defer { main.orderOut(nil); main.close() }
            try await Task.sleep(for: .milliseconds(800))
            try captureRegion(main, to: root.appendingPathComponent("workspace-\(dark ? "dark" : "light").png"))
            main.orderOut(nil)
            let launcher = AskLauncherView(model: fixture.model, onDismiss: {})
                .environment(\.interfaceStyle, .liquidGlass)
                .environment(\.colorScheme, dark ? .dark : .light)
            let panel = makeWindow(launcher, dark: dark, size: .init(width: AskMetrics.launcherWidth, height: 370))
            panel.level = NSWindow.Level(rawValue: back.level.rawValue + 1)
            panel.orderFront(nil)
            defer { panel.orderOut(nil); panel.close() }
            try await Task.sleep(for: .milliseconds(800))
            try captureRegion(panel, to: root.appendingPathComponent("launcher-\(dark ? "dark" : "light").png"))
        }
    }

    private func captureRegion(_ window: NSWindow, to file: URL) throws {
        let frame = window.frame
        let top = NSScreen.screens[0].frame.maxY - frame.maxY
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-R", "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))", file.path]
        try capture.run()
        capture.waitUntilExit()
        #expect(capture.terminationStatus == 0)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func centerColor(_ window: NSWindow) throws -> NSColor {
        let host = try #require(window.contentView)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
            .usingColorSpace(.sRGB))
    }

    private func capture(_ window: NSWindow, to file: URL) throws {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try capture.run()
        capture.waitUntilExit()
        #expect(capture.terminationStatus == 0)
    }
}
