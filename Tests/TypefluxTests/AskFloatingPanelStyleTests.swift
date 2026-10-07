import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Native rendering checks; the window server's refraction is not part of bitmap captures.
@Suite("Floating panel readability", .serialized)
@MainActor
struct AskFloatingPanelStyleTests {
    @Test func `light panels shield text from dark and saturated backdrops`() async throws {
        let size = NSSize(width: 160, height: 100)
        for placement in [AskGlassPlacement.floating, .menu] {
            for material in [AskGlassMaterial.visualEffect, .liquidGlass, .opaque] {
                let panel = AskGlassBackground(material: material, corner: 16,
                                               opaqueFill: AskTheme.launcherSurface, placement: placement)
                let black = try await render(panel.background(Color.black), size: size, appearance: .aqua)
                let blue = try await render(panel.background(Color.blue), size: size, appearance: .aqua)
                let darkFill = try pixel(black, x: 80, y: 50), blueFill = try pixel(blue, x: 80, y: 50)
                #expect(darkFill.redComponent > 0.84 && darkFill.greenComponent > 0.84 && darkFill.blueComponent > 0.84)
                #expect(abs(darkFill.blueComponent - blueFill.blueComponent) < 0.14)
                #expect(abs(blueFill.blueComponent - blueFill.redComponent) < 0.14)
            }
        }
    }

    @Test func `clipboard opaque fallback has rounded corners in both contrast modes`() async throws {
        let model = ClipboardPanelModel()
        model.reset(entries: [])
        let size = NSSize(width: ClipboardPanelView.width, height: ClipboardPanelView.height)
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua,
                           .accessibilityHighContrastDarkAqua] {
            let panel = ClipboardPanelView(model: model, focusRequest: 0)
                .environment(\.askGlassMaterialOverride, .opaque)
            let bitmap = try await render(panel, size: size, appearance: appearance)
            let fill = try pixel(bitmap, x: 40, y: 160)
            #expect(fill.alphaComponent > 0.999)
            #expect(try pixel(bitmap, x: 0, y: 0).alphaComponent < 0.01)
            if appearance == .aqua || appearance == .accessibilityHighContrastAqua {
                #expect(fill.redComponent > 0.95)
            } else {
                #expect(fill.redComponent < 0.2)
            }
        }
    }

    @Test func `selected plugin rows use a soft wash in both appearances`() async throws {
        let row = AskPluginItemRow(item: AskPluginItem(id: "word", title: "serendipity", subtitle: "A happy discovery"),
                                   symbol: "character.book.closed", selected: true, emphasized: true,
                                   height: AskPluginResultsView.itemHeight, onPick: {})
            .background(AskTheme.launcherSurface)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let bitmap = try await render(row, size: NSSize(width: 560, height: 44), appearance: appearance)
            let fill = try pixel(bitmap, x: 520, y: 22)
            // A saturated accent fill would make the red channel much darker in light mode.
            if appearance == .aqua {
                #expect(fill.redComponent > 0.85)
            } else {
                #expect(fill.redComponent < 0.3 && fill.blueComponent < 0.4)
            }
        }
    }

    /// Review artifacts use production views and synthetic content, without accounts or remote calls.
    @Test func `write review snapshots when requested`() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_PANEL_STYLE_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        let action = AskPluginAction(kind: .openWordBook(key: nil), title: L("ask.plugin.action.open"),
                                     symbol: "character.book.closed", shortcut: .enter)
        let open = AskPluginItem(id: AskTranslatePlugin.openAllItem, title: L("ask.wordBook.list.openAll"),
                                 subtitle: L("ask.wordBook.list.openAll.detail"),
                                 icon: .symbol("character.book.closed"), actions: [action])
        let words = [
            AskPluginItem(id: "serendipity", title: "serendipity", subtitle: "意外发现美好事物的机缘"),
            AskPluginItem(id: "clarity", title: "clarity", subtitle: "清晰；明确")
        ]
        let plan = AskPluginPlan(mode: .live, title: L("ask.wordBook.title"))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (label, items, note) in [("empty", [open], Optional(L("ask.wordBook.list.empty"))),
                                         ("recent", [open] + words, nil)] {
                let output = AskPluginOutput(body: "", original: "", meta: [], source: L("ask.plugin.source.wordBook"),
                                             note: note, actions: [], items: items)
                let display = AskPluginDisplay(title: L("ask.plugin.translate.title"), symbol: "character.book.closed",
                                               phase: .done(plan, output))
                let view = AskPluginResultsView(display: display, question: "", onMain: {}, onAction: { _ in },
                                                onAskAI: {}, onHighlight: { _ in })
                    .background(AskGlassBackground(material: .opaque, corner: 16, opaqueFill: AskTheme.launcherSurface))
                let bitmap = try await render(
                    view,
                    size: NSSize(width: 650, height: AskPluginResultsView.height(for: display)),
                    appearance: appearance
                )
                try save(bitmap, to: root.appendingPathComponent("wordbook-\(label)-\(name).png"))
            }
            let clipboard = ClipboardPanelModel()
            clipboard.reset(entries: [ClipboardTestSupport.entry(.text, text: "会议记录", sourceAppName: "Notes"),
                                      ClipboardTestSupport.entry(.link, text: "https://example.com")])
            let bitmap = try await render(ClipboardPanelView(model: clipboard, focusRequest: 0),
                                          size: NSSize(
                                              width: ClipboardPanelView.width,
                                              height: ClipboardPanelView.height
                                          ),
                                          appearance: appearance)
            try save(bitmap, to: root.appendingPathComponent("clipboard-\(name).png"))
            try await writeMenuSnapshot(appearance: appearance, file: root.appendingPathComponent("menu-\(name).png"))
        }
    }

    private func writeMenuSnapshot(appearance: NSAppearance.Name, file: URL) async throws {
        let menu = AskGlassCardSurface(corner: AskGlassCardSurface<EmptyView>.menuCorner) {
            VStack(spacing: 2) {
                AskPopoverRow(title: "MiniMax M3", caption: "205K 上下文 · 16.4K 输出", selected: true, action: {})
                AskPopoverRow(title: "DeepSeek Pro", caption: "205K 上下文 · 16.4K 输出", selected: false, action: {})
            }.padding(.vertical, 6)
        }
        let menuBitmap = try await render(menu, size: NSSize(width: 320, height: 120), appearance: appearance)
        try save(menuBitmap, to: file)
    }

    private func save(_ bitmap: NSBitmapImageRep, to file: URL) throws {
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
    }

    private func pixel(_ bitmap: NSBitmapImageRep, x column: Int, y row: Int) throws -> NSColor {
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        return try #require(bitmap.colorAt(x: Int(CGFloat(column) * scale), y: Int(CGFloat(row) * scale))?
            .usingColorSpace(.sRGB))
    }

    private func render(_ view: some View, size: NSSize,
                        appearance: NSAppearance.Name) async throws -> NSBitmapImageRep {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }
}
