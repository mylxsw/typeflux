import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Footer controls rendered natively: switches highlight only their icons,
/// and the permission menu is drawn in its mode's colour, not the launcher's accent.
@Suite("Launcher palette rendering", .serialized, .exclusiveUIState)
@MainActor
struct AskLauncherPaletteRenderTests {
    private struct Census {
        var blue = 0, red = 0, grey = 0, green = 0, orange = 0
    }

    @Test func `permission menu label is drawn in its mode colour`() async throws {
        func census(_ mode: AskPermissionMode, bare: Bool, _ appearance: NSAppearance.Name) async throws -> Census {
            let menu = AskPermissionModeMenu(mode: mode, compact: true, bare: bare, onSelect: { _ in })
                .tint(AskTheme.accent)
            let size = NSSize(width: mode == .yolo ? 90 : 60, height: 30)
            return try self.census(await render(menu, size: size, appearance: appearance))
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for bare in [false, true] {
                let strict = try await census(.strict, bare: bare, appearance)
                #expect(strict.green > 0 && strict.blue == 0 && strict.orange == 0, "strict is green")
                let standard = try await census(.standard, bare: bare, appearance)
                #expect(standard.blue > 0 && standard.green == 0 && standard.orange == 0, "standard is blue")
                let yolo = try await census(.yolo, bare: bare, appearance)
                #expect(yolo.orange > 0 && yolo.blue == 0 && yolo.green == 0, "YOLO is orange")
            }
        }
    }

    @Test func `permission modes each have their own colour`() {
        #expect(AskPermissionModeMenu.tint(.strict) == StudioTheme.success)
        #expect(AskPermissionModeMenu.tint(.standard) == StudioTheme.accent)
        #expect(AskPermissionModeMenu.tint(.yolo) == StudioTheme.warning)
        for mode in AskPermissionMode.allCases {
            #expect(AskPermissionModeMenu.labelColor(mode) == AskPermissionModeMenu.tint(mode))
        }
    }

    @Test func `only the current mode gets a coloured menu image`() throws {
        let size = try #require(AskPermissionModeMenu.menuSymbolImage(.strict)).size
        for mode in AskPermissionMode.allCases {
            let neutral = try #require(AskPermissionModeMenu.menuImage(mode, selected: false, dark: false))
            #expect(neutral.isTemplate, "other modes keep the menu's template symbol")
            #expect(neutral.size == size, "all menu rows use the same icon size")
        }
        for dark in [false, true] {
            let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
            for mode in AskPermissionMode.allCases {
                let image = try #require(AskPermissionModeMenu.menuImage(mode, selected: true, dark: dark))
                #expect(!image.isTemplate, "a template image would be redrawn in the text colour")
                #expect(image.size == size, "selection keeps the same icon size")
                #expect(image.accessibilityDescription == L("ask.mode.current"))
                let census = try census(draw(image))
                var expected = NSColor.clear
                appearance.performAsCurrentDrawingAppearance {
                    expected = NSColor(AskPermissionModeMenu.tint(mode)).usingColorSpace(.sRGB) ?? .clear
                }
                switch mode {
                case .strict: #expect(census.green > 0 && census.blue == 0 && census.orange == 0)
                case .standard: #expect(census.blue > 0 && census.green == 0 && census.orange == 0)
                case .yolo: #expect(census.orange > 0 && census.blue == 0 && census.green == 0)
                }
                #expect(try dominant(draw(image)).isClose(to: expected),
                        "resolved for the \(dark ? "dark" : "light") menu")
            }
        }
    }

    @Test func `the current mode's menu colour follows the appearance`() throws {
        for mode in AskPermissionMode.allCases {
            let light = try dominant(draw(#require(AskPermissionModeMenu.menuImage(mode, selected: true, dark: false))))
            let dark = try dominant(draw(#require(AskPermissionModeMenu.menuImage(mode, selected: true, dark: true))))
            #expect(!light.isClose(to: dark, tolerance: 0.04), "\(mode) uses its light and dark theme colours")
        }
    }

    @Test func `the coloured menu image keeps the symbol's cut-out glyph`() throws {
        for mode in AskPermissionMode.allCases {
            let symbol = try #require(AskPermissionModeMenu.menuSymbolImage(mode))
            let coloured = try #require(AskPermissionModeMenu.menuImage(mode, selected: true, dark: true))
            #expect(coloured.size == symbol.size, "drawn at the size the menu gives its template symbols")
            // Both drawn at the size a menu shows them, on a Retina-density backing store.
            let plain = try draw(symbol, size: symbol.size, scale: 4)
            let tinted = try draw(coloured, size: symbol.size, scale: 4)
            var mismatched = 0, inked = 0
            for x in 0 ..< plain.pixelsWide {
                for y in 0 ..< plain.pixelsHigh {
                    let a = plain.colorAt(x: x, y: y)?.alphaComponent ?? 0
                    let b = tinted.colorAt(x: x, y: y)?.alphaComponent ?? 0
                    if a > 0.5 { inked += 1 }
                    if (a > 0.5) != (b > 0.5) { mismatched += 1 }
                }
            }
            #expect(inked > 0)
            #expect(mismatched * 50 < inked,
                    "\(mode) is the same shape as its template symbol, glyph included: \(mismatched)/\(inked)")
        }
    }

    @Test func `the mode submenu colours the current mode instead of a checkmark`() async throws {
        let rows = AskCommandCatalog.submenu(.permissionMode, context: AskCommandContext(permissionMode: .yolo))
            .map { AskCommandMatcher.Match(command: $0, score: 1, highlights: []) }
        #expect(rows.map(\.command.selected) == [false, false, true])
        var state = AskCommandPaletteState()
        // The highlight rests on strict, which is not the current mode.
        state.update(rows: rows, query: "")
        #expect(state.highlighted == 0)
        let height = AskCommandPaletteView.height(for: state, compact: true, maximumHeight: 400)
        let palette = AskCommandPaletteView(state: state, compact: true, maximumHeight: 400,
                                            onPick: { _ in }, onHighlight: { _ in }, onManage: nil)
            .environment(\.askGlassMaterialOverride, .opaque)
        let census = try census(await render(palette, size: NSSize(width: 520, height: height), appearance: .darkAqua))
        #expect(census.orange > 0, "the current mode, YOLO, is drawn orange")
        #expect(census.green == 0, "the highlighted but unselected strict row stays neutral")
    }

    @Test func `permission menus omit chevrons and the launcher shows only symbols`() {
        func width(_ mode: AskPermissionMode, bare: Bool) -> CGFloat {
            NSHostingView(rootView: AskPermissionModeMenu(mode: mode, compact: true, bare: bare, onSelect: { _ in }))
                .fittingSize.width
        }
        #expect(width(.yolo, bare: true) < width(.yolo, bare: false) - 20, "YOLO drops its word")
        #expect(abs(width(.standard, bare: true) - width(.standard, bare: false)) < 0.5,
                "Both composer variants omit the chevron")
    }

    @Test func `footer status icons match the storage lock visually`() async throws {
        let size = NSSize(width: AskMetrics.composerControlHeight, height: AskMetrics.composerControlHeight)
        func blueMetrics(_ view: some View) async throws -> (width: CGFloat, height: CGFloat, ink: Int) {
            let bitmap = try await render(view, size: size, appearance: .darkAqua)
            var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1, ink = 0
            for y in 0 ..< bitmap.pixelsHigh {
                for x in 0 ..< bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if color.blueComponent - color.redComponent > 0.2 && color.blueComponent > color.greenComponent {
                        minX = min(minX, x)
                        maxX = max(maxX, x)
                        minY = min(minY, y)
                        maxY = max(maxY, y)
                        ink += 1
                    }
                }
            }
            let width = CGFloat(try #require(maxX >= minX ? maxX - minX + 1 : nil))
                * size.width / CGFloat(bitmap.pixelsWide)
            let height = CGFloat(try #require(maxY >= minY ? maxY - minY + 1 : nil))
                * size.height / CGFloat(bitmap.pixelsHigh)
            return (width, height, ink)
        }
        let lock = try await blueMetrics(
            Image(systemName: "lock")
                .font(.system(size: AskMetrics.footerStatusSymbolSize, weight: .semibold))
                .foregroundStyle(StudioTheme.accent)
        )
        let shield = try await blueMetrics(AskPermissionModeMenu(mode: .standard, compact: true, bare: true,
                                                                onSelect: { _ in }))
        let camera = try await blueMetrics(AskIconChipFace(item: .init(kind: .screenshot,
            systemImage: "camera.viewfinder", style: .active, title: "Screenshot")))
        let brain = try await blueMetrics(AskIconChipFace(item: .init(kind: .memory,
            systemImage: "brain", style: .active, title: "Memory")))
        for (name, metrics) in [("shield", shield), ("camera", camera)] {
            #expect(abs(metrics.height - lock.height) <= 2,
                    "\(name): \(metrics.height)pt versus lock: \(lock.height)pt")
        }
        #expect(brain.width <= camera.width + 2, "brain width: \(brain.width)pt, camera: \(camera.width)pt")
        #expect(brain.height <= camera.height + 1 && brain.height >= camera.height - 7)
        #expect(Double(brain.ink) <= Double(camera.ink) * 1.3,
                "brain ink: \(brain.ink), camera: \(camera.ink)")
    }

    @Test func `active and inactive switches have no background`() async throws {
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
            #expect(lit.alphaComponent < 0.02)
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
        case page, wallpaper, darkWindow
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
            case .darkWindow:
                ZStack {
                    Color(.sRGB, white: 0.16, opacity: 1)
                    HStack(spacing: 0) {
                        Color(red: 0.05, green: 0.48, blue: 0.65)
                        Color(red: 0.25, green: 0.40, blue: 0.75)
                        Color(red: 0.28, green: 0.55, blue: 0.40)
                        Color(red: 0.72, green: 0.43, blue: 0.12)
                    }.frame(height: 130)
                    VStack(spacing: 12) {
                        ForEach(0 ..< 12) { _ in
                            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                        }
                    }
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
                if blue - red > 0.2, blue > color.greenComponent { census.blue += 1 }
                if red - blue > 0.3 { census.red += 1 }
                if red < 0.7, abs(blue - red) < 0.08 { census.grey += 1 }
                let green = color.greenComponent
                if green - max(red, blue) > 0.15 { census.green += 1 }
                if red - green > 0.15, green - blue > 0.15 { census.orange += 1 }
            }
        }
        return census
    }

    /// Draws `image` into `size` points on a backing store `scale` times denser.
    private func draw(_ image: NSImage, size: NSSize = NSSize(width: 40, height: 40),
                      scale: CGFloat = 1) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    /// The most opaque pixel, which sits on the symbol's stroke.
    private func dominant(_ bitmap: NSBitmapImageRep) throws -> NSColor {
        var best = NSColor.clear
        for x in 0 ..< bitmap.pixelsWide {
            for y in 0 ..< bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.alphaComponent > best.alphaComponent { best = color }
            }
        }
        return best
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

private extension NSColor {
    func isClose(to other: NSColor, tolerance: CGFloat = 0.06) -> Bool {
        abs(redComponent - other.redComponent) < tolerance
            && abs(greenComponent - other.greenComponent) < tolerance
            && abs(blueComponent - other.blueComponent) < tolerance
    }
}
