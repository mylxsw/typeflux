import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Renders the Ask surfaces in both interface styles. A plain run renders each
/// scene once, classic in light, so the flat layout is exercised; with
/// `TYPEFLUX_CLASSIC_SCREENSHOTS=<dir>` every style and appearance is rendered
/// and the PNGs are written there for review. Bitmap captures cannot show the
/// window server's blur, so glass scenes render with their opaque fallback and
/// only the classic ones are exact.
@Suite("Interface style snapshots", .serialized, .exclusiveUIState)
@MainActor
struct AskClassicStyleVisualTests {
    private static let directory = ProcessInfo.processInfo.environment["TYPEFLUX_CLASSIC_SCREENSHOTS"]
    private static var styles: [InterfaceStyle] { directory == nil ? [.classic] : InterfaceStyle.allCases }
    private static var appearances: [Bool] { directory == nil ? [false] : [true, false] }

    private func conversation(id: String, title: String, minutesAgo: Double, local: Bool = false) -> AskConversation {
        let date = Date().addingTimeInterval(-minutesAgo * 60)
        var value = AskConversation(id: id, title: title, revision: 2, updatedAt: date, messages: [
            .init(id: id + "-q", role: "user", text: "请帮我总结提炼选中的这段内容，输出三条要点。", createdAt: date, runId: id + "-run"),
            .init(id: id + "-a", role: "assistant",
                  text: """
                  这段内容主要讲了三件事：

                  1. **统一样式开关**：界面风格由设置集中控制，组件不再各自判断。
                  2. **扁平回退**：经典风格使用不透明表面与细分隔线，不做模糊与折射。
                  3. **结构不变**：侧栏、标题栏、输入框的位置保持一致，只替换材质。

                  ```swift
                  settings.interfaceStyle = .classic
                  ```
                  """,
                  createdAt: date, runId: id + "-run")
        ])
        value.run = .init(id: id + "-run", deviceId: "device", status: "completed", steps: 1, updatedAt: date,
                          tools: [], pending: [])
        value.usage = .init(version: 1, since: date, historicalGap: false,
                            total: .init(microcredits: 328_970_000, calls: 2), runs: [:])
        return value
    }

    private func seededFixture() async throws -> AskTestFixture {
        let fixture = try AskTestFixture()
        // Minutes ago, so the history shows today, yesterday and earlier groups.
        let ages: [String: Double] = ["summary": 30, "weather": 60 * 30, "page": 60 * 50, "translate": 60 * 24 * 4]
        let titles = ["summary": "请帮我总结提炼选中的这段内容", "weather": "帮我实现一个查询天气的脚本",
                      "page": "帮我实现一个查询天气的页面", "translate": "翻译我选中的文字"]
        for (id, age) in ages {
            await fixture.api.seed(conversation(id: id, title: titles[id] ?? id, minutesAgo: age))
        }
        await fixture.model.refreshHistory()
        return fixture
    }

    @discardableResult
    private func render(_ view: some View, name: String, style: InterfaceStyle, dark: Bool, size: NSSize,
                        settle: Duration = .milliseconds(300), invalidate: () -> Void = {}) async throws -> Data {
        _ = NSApplication.shared
        func content() -> some View {
            view.environment(\.interfaceStyle, style)
                // The bitmap cannot show behind-window glass; render its opaque fallback.
                .environment(\.askGlassMaterialOverride, style.usesGlass ? .opaque : nil)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                .environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: size.width, height: size.height)
                .background(style.usesGlass ? AskTheme.surface : AskClassic.canvas)
        }
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        var restored = false
        defer { if !restored { AppLocalization.shared.setLanguage(previous) } }
        let hosting = NSHostingView(rootView: content())
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.appearance = hosting.appearance
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        AppLocalization.shared.setLanguage(previous)
        try await Task.sleep(for: settle)
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        hosting.rootView = content()
        invalidate()
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        AppLocalization.shared.setLanguage(previous)
        restored = true
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 4000, "\(name) rendered nothing")
        if let directory = Self.directory {
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try png.write(to: root.appendingPathComponent(name + ".png"))
        }
        return png
    }

    /// The light classic window: the sidebar's grey reaches the window's leading
    /// edge, a dark hairline divides it from the white conversation canvas.
    private func expectFlushColumns(_ png: Data) throws {
        let bitmap = try #require(NSBitmapImageRep(data: png))
        func white(_ column: Int, _ row: Int) throws -> CGFloat {
            try #require(bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB)).whiteComponentApproximation
        }
        // 2x pixels, mid-height, below the history rows and above the footer.
        let row = bitmap.pixelsHigh / 2
        #expect(abs(try white(1, row) - 0.961) < 0.02, "sidebar must be flush with the window edge")
        #expect(abs(try white(200, row) - 0.961) < 0.02)
        #expect(try white(Int(AskMetrics.sidebarWidth * 2) + 40, row) > 0.99, "canvas")
        let divider = (Int(AskMetrics.sidebarWidth * 2) - 4 ... Int(AskMetrics.sidebarWidth * 2) + 2)
            .map { (try? white($0, row)) ?? 1 }.min() ?? 1
        #expect(divider < 0.93, "the columns are divided by a hairline")
    }

    private func renderChat(_ fixture: AskTestFixture, _ scene: String, _ style: InterfaceStyle, dark: Bool,
                            size: NSSize, showsUsage: Bool = false) async throws {
        try await render(AskConversationView(model: fixture.model, showsUsage: showsUsage),
                         name: name(scene, style, dark: dark), style: style, dark: dark, size: size,
                         settle: .milliseconds(600), invalidate: { fixture.model.objectWillChange.send() })
    }

    private func name(_ scene: String, _ style: InterfaceStyle, dark: Bool) -> String {
        "\(scene)-\(style.rawValue)-\(dark ? "dark" : "light")"
    }

    @Test func `chat window scenes`() async throws {
        let fixture = try await seededFixture()
        defer { fixture.model.resetSession(); try? FileManager.default.removeItem(at: fixture.root) }
        for style in Self.styles {
            for dark in Self.appearances {
                fixture.model.newConversation()
                try await render(AskConversationView(model: fixture.model), name: name("chat-empty", style, dark: dark),
                                 style: style, dark: dark, size: .init(width: 1280, height: 800),
                                 invalidate: { fixture.model.objectWillChange.send() })
                await fixture.model.select("summary")
                let thread = try await render(AskConversationView(model: fixture.model),
                                              name: name("chat-thread", style, dark: dark),
                                              style: style, dark: dark, size: .init(width: 1280, height: 800),
                                              settle: .milliseconds(600),
                                              invalidate: { fixture.model.objectWillChange.send() })
                if style == .classic, !dark { try expectFlushColumns(thread) }
                try await renderChat(fixture, "chat-usage", style, dark: dark, size: .init(width: 1480, height: 820),
                                     showsUsage: true)
                try await renderChat(fixture, "chat-narrow", style, dark: dark, size: .init(width: 620, height: 720))
            }
        }
    }

    @Test func `collapsed sidebar`() async throws {
        let fixture = try await seededFixture()
        let key = "ask.sidebarCollapsed"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            fixture.model.resetSession(); try? FileManager.default.removeItem(at: fixture.root)
        }
        await fixture.model.select("summary")
        for style in Self.styles {
            for dark in Self.appearances {
                try await renderChat(fixture, "chat-collapsed", style, dark: dark,
                                     size: .init(width: 1100, height: 700))
            }
        }
    }

    @Test func `settings row`() async throws {
        for dark in Self.appearances {
            try await render(SettingsRowScene(), name: "settings-row-\(dark ? "dark" : "light")", style: .classic,
                             dark: dark, size: .init(width: 900, height: 120))
        }
    }

    @Test func `floating surfaces`() async throws {
        let fixture = try await seededFixture()
        defer { fixture.model.resetSession(); try? FileManager.default.removeItem(at: fixture.root) }
        let backdrop = LinearGradient(colors: [.white, .orange.opacity(0.6), .pink.opacity(0.6)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
        for style in Self.styles {
            for dark in Self.appearances {
                let launcher = AskLauncherView(model: fixture.model, onDismiss: {})
                    .frame(width: AskMetrics.launcherWidth)
                    .padding(28)
                    .background(backdrop)
                try await render(launcher, name: name("launcher", style, dark: dark), style: style, dark: dark,
                                 size: .init(width: AskMetrics.launcherWidth + 56, height: 300))
                let menu = AskGlassCardSurface(kind: .menu) {
                    VStack(alignment: .leading, spacing: 2) {
                        AskPopoverRow(title: "MiniMax M3", note: "默认", caption: nil, selected: true, action: {})
                        AskPopoverRow(title: "DeepSeek V4", caption: nil, selected: false, action: {})
                        AskPopoverRow(title: "Qwen 3.5 Max", caption: "无法读取图片", selected: false, enabled: false,
                                      action: {})
                    }
                    .padding(6)
                    .frame(width: 260)
                }
                .padding(30)
                .background(backdrop)
                try await render(menu, name: name("menu", style, dark: dark), style: style, dark: dark,
                                 size: .init(width: 320, height: 220))
                let palette = AskSearchPaletteView(conversations: fixture.model.conversations,
                                                   available: AskPaletteAction.allCases,
                                                   onAction: { _ in }, onOpen: { _ in }, onClose: {})
                try await render(palette, name: name("palette", style, dark: dark), style: style, dark: dark,
                                 size: .init(width: 900, height: 620))
            }
        }
    }
}

/// The renamed setting, built when rendered so its copy is read in the render's language.
private struct SettingsRowScene: View {
    var body: some View {
        StudioSettingRow(title: L("settings.interfaceStyle.title"), subtitle: L("settings.interfaceStyle.subtitle")) {
            StudioSegmentedPicker(options: InterfaceStyle.allCases.map { (label: $0.displayName, value: $0) },
                                  selection: .constant(InterfaceStyle.classic))
                .frame(width: StudioTheme.Layout.appearancePickerWidth)
        }
        .padding(24)
        .background(StudioTheme.surface)
    }
}

private extension NSColor {
    /// The mean of the red, green and blue components, for neutral greys.
    var whiteComponentApproximation: CGFloat { (redComponent + greenComponent + blueComponent) / 3 }
}
