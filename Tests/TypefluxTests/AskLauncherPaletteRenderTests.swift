import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Footer controls rendered natively: switches show "on" with a tinted well,
/// menus stay neutral under the launcher's accent tint.
@Suite("Launcher palette rendering", .serialized)
@MainActor
struct AskLauncherPaletteRenderTests {
    private struct Census {
        var blue = 0, red = 0, grey = 0
    }

    @Test func `permission menu stays neutral under the accent tint`() async throws {
        for mode in [AskPermissionMode.strict, .standard] {
            let menu = AskPermissionModeMenu(mode: mode, compact: true, onSelect: { _ in }).tint(AskTheme.accent)
            let census = try census(await render(menu, size: NSSize(width: 60, height: 30)))
            #expect(census.blue == 0, "a menu must not look like a switch that is on")
            #expect(census.grey > 0)
        }
        let yolo = AskPermissionModeMenu(mode: .yolo, compact: true, onSelect: { _ in }).tint(AskTheme.accent)
        let census = try census(await render(yolo, size: NSSize(width: 90, height: 30)))
        #expect(census.red > 0)
        #expect(census.blue == 0)
    }

    @Test func `permission menu colours only yolo`() {
        #expect(AskPermissionModeMenu.labelColor(.standard) == StudioTheme.textSecondary)
        #expect(AskPermissionModeMenu.labelColor(.strict) == StudioTheme.textSecondary)
        #expect(AskPermissionModeMenu.labelColor(.yolo) == StudioTheme.danger)
        #expect(AskPermissionModeMenu.wellFill(.standard) == .clear)
        #expect(AskPermissionModeMenu.wellFill(.yolo) == StudioTheme.danger.opacity(0.11))
    }

    @Test func `an on switch sits in a tinted well and an off switch does not`() async throws {
        let on = AskContextItem(kind: .screenshot, systemImage: "camera.viewfinder", style: .active,
                                title: "Screenshot")
        var off = on
        off.style = .neutral
        let size = NSSize(width: AskContextChips.chipSize, height: AskContextChips.chipSize)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            // Inside the well, clear of the glyph.
            let wellPoint = (x: Int(AskIconChipFace.wellInset) + 2, y: Int(size.height / 2))
            let lit = try pixel(await render(AskIconChipFace(item: on), size: size, appearance: appearance),
                                at: wellPoint)
            #expect(lit.alphaComponent > 0.1)
            #expect(lit.blueComponent > lit.redComponent + 0.1)
            let unlit = try pixel(await render(AskIconChipFace(item: off), size: size, appearance: appearance),
                                  at: wellPoint)
            #expect(unlit.alphaComponent < 0.02)
        }
    }

    // MARK: - Review snapshots

    /// Production launcher over a bright page and a saturated wallpaper, captured
    /// from the screen so the system glass is included, plus the opaque fallback.
    @Test func `write launcher palette snapshots when requested`() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_LAUNCHER_PALETTE_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }

        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        await fixture.model.prepareLauncher()
        let titles = ["读一下当前网页并总结要点。", "tell me the latest price of eth", "find a file named \"typeflux\""]
        for (index, title) in titles.enumerated() {
            try await fixture.cache.save(.init(id: "c\(index)", title: title, revision: 1,
                                               updatedAt: Date().addingTimeInterval(-Double(index + 1) * 2400),
                                               messages: []),
                                         owner: fixture.sessionState.owner)
        }
        await fixture.model.loadCachedHistoryIfNeeded()
        // Screenshot on, memory off: the footer shows one switch in each state.
        fixture.model.launcherDraft.includeScreenshot = true
        fixture.model.launcherDraft.memory = AskMemory(global: "Prefers short answers.", app: nil)
        fixture.model.launcherDraft.memoryOff = true
        fixture.model.launcherDraft.source = nil
        fixture.model.launcherDraft.selection = nil

        let home = AskLauncherSuggestions.height(for: fixture.model.launcherHome())
        let size = NSSize(width: AskMetrics.launcherWidth,
                          height: AskMetrics.launcherHeight(editor: 32, banners: 0, suggestions: home))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let opaque = AskLauncherView(model: fixture.model, onDismiss: {})
                .environment(\.askGlassMaterialOverride, .opaque)
            try save(await render(opaque, size: size, appearance: appearance),
                     to: root.appendingPathComponent("launcher-opaque-\(name).png"))
            for backdrop in Backdrop.allCases {
                try await captureOnScreen(AskLauncherView(model: fixture.model, onDismiss: {}), size: size,
                                          backdrop: backdrop, appearance: appearance,
                                          to: root.appendingPathComponent("launcher-glass-\(backdrop)-\(name).png"))
            }
        }
    }

    private enum Backdrop: String, CaseIterable, CustomStringConvertible {
        case page, wallpaper
        var description: String { rawValue }

        @ViewBuilder var view: some View {
            switch self {
            case .page:
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 18) {
                        Text("multica").bold()
                        Text("Product"); Text("Docs"); Text("Pricing"); Text("Blog")
                    }
                    .font(.system(size: 13)).foregroundStyle(Color.black.opacity(0.8))
                    LinearGradient(colors: [.orange, .yellow, .blue, .purple],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 12))
                    ForEach([0.7, 0.92, 0.55, 0.8], id: \.self) { width in
                        GeometryReader { proxy in
                            Capsule().fill(Color(white: 0.85)).frame(width: proxy.size.width * width, height: 10)
                        }.frame(height: 10)
                    }
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.95))
                        RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.06, green: 0.09, blue: 0.16))
                        RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.95))
                    }
                    .frame(height: 90)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 40).padding(.vertical, 26)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
            case .wallpaper:
                ZStack {
                    LinearGradient(colors: [Color(red: 0.96, green: 0.83, blue: 0.40),
                                            Color(red: 0.99, green: 0.63, blue: 0.52),
                                            Color(red: 0.63, green: 0.55, blue: 0.82)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    RadialGradient(colors: [Color(red: 0.42, green: 0.55, blue: 1), .clear], center: .topTrailing,
                                   startRadius: 0, endRadius: 360)
                    RadialGradient(colors: [Color(red: 0.24, green: 0.86, blue: 0.59), .clear], center: .bottom,
                                   startRadius: 0, endRadius: 320)
                }
            }
        }
    }

    /// Puts a backdrop window and the launcher card in a panel above it on screen,
    /// then captures that region with `screencapture`, which includes the glass.
    private func captureOnScreen(_ view: some View, size: NSSize, backdrop: Backdrop,
                                 appearance: NSAppearance.Name, to file: URL) async throws {
        let screen = try #require(NSScreen.main)
        // Kept narrow and at the screen's top-left so other windows stay out of the capture.
        let (side, edge): (CGFloat, CGFloat) = (20, 60)
        let area = NSRect(x: screen.visibleFrame.minX + 4, y: screen.visibleFrame.maxY - 30 - size.height - edge * 2,
                          width: size.width + side * 2, height: size.height + edge * 2)
        let back = NSWindow(contentRect: area, styleMask: .borderless, backing: .buffered, defer: false)
        back.isReleasedWhenClosed = false
        back.level = .floating
        back.appearance = NSAppearance(named: appearance)
        back.contentView = NSHostingView(rootView: backdrop.view.frame(width: area.width, height: area.height))
        let panel = NSPanel(contentRect: area.insetBy(dx: side, dy: edge),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.appearance = NSAppearance(named: appearance)
        panel.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        back.orderFrontRegardless()
        panel.orderFrontRegardless()
        defer {
            panel.orderOut(nil); panel.close()
            back.orderOut(nil); back.close()
        }
        // Let the window server composite the glass before capturing.
        try await Task.sleep(for: .milliseconds(900))
        let top = screen.frame.maxY - area.maxY
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-R\(Int(area.minX)),\(Int(top)),\(Int(area.width)),\(Int(area.height))", file.path]
        try capture.run()
        capture.waitUntilExit()
        #expect(capture.terminationStatus == 0)
    }

    // MARK: - Helpers

    private func census(_ bitmap: NSBitmapImageRep) throws -> Census {
        var census = Census()
        for x in 0 ..< bitmap.pixelsWide {
            for y in 0 ..< bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else {
                    continue
                }
                let (red, blue) = (color.redComponent, color.blueComponent)
                if blue - red > 0.2 { census.blue += 1 }
                if red - blue > 0.3 { census.red += 1 }
                if red < 0.7, abs(blue - red) < 0.08 { census.grey += 1 }
            }
        }
        return census
    }

    private func pixel(_ bitmap: NSBitmapImageRep, at point: (x: Int, y: Int)) throws -> NSColor {
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        return try #require(bitmap.colorAt(x: Int(CGFloat(point.x) * scale), y: Int(CGFloat(point.y) * scale))?
            .usingColorSpace(.sRGB))
    }

    private func save(_ bitmap: NSBitmapImageRep, to file: URL) throws {
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
    }

    private func render(_ view: some View, size: NSSize,
                        appearance: NSAppearance.Name = .aqua) async throws -> NSBitmapImageRep {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }
}
