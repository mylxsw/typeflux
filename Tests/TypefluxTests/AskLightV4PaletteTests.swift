import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask light v4 palette", .serialized, .exclusiveUIState)
@MainActor
struct AskLightV4PaletteTests {
    private func resolve(_ color: Color, dark: Bool) throws -> NSColor {
        var result: NSColor?
        try #require(NSAppearance(named: dark ? .darkAqua : .aqua)).performAsCurrentDrawingAppearance {
            result = NSColor(color).usingColorSpace(.sRGB)
        }
        return try #require(result)
    }

    private func expectColor(_ actual: Color, _ expected: Color, dark: Bool, context: String = "") throws {
        let actualColor = try resolve(actual, dark: dark), expectedColor = try resolve(expected, dark: dark)
        let details = "\(context): \(actualColor) vs \(expectedColor)"
        #expect(abs(actualColor.redComponent - expectedColor.redComponent) < 0.002, "\(details)")
        #expect(abs(actualColor.greenComponent - expectedColor.greenComponent) < 0.002, "\(details)")
        #expect(abs(actualColor.blueComponent - expectedColor.blueComponent) < 0.002, "\(details)")
        #expect(abs(actualColor.alphaComponent - expectedColor.alphaComponent) < 0.002, "\(details)")
    }

    private func rgb(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: alpha)
    }

    @Test func `light workspace tokens and neutral launcher palette`() throws {
        let pairs: [(Color, Color)] = [
            (AskTheme.border, rgb(15, 23, 42, 0.08)),
            (AskTheme.separator, rgb(15, 23, 42, 0.08)),
            (AskTheme.launcherSeparator, rgb(15, 23, 42, 0.08)),
            (AskTheme.cardBorder, rgb(15, 23, 42, 0.09)),
            (AskTheme.librarySeparator, rgb(15, 23, 42, 0.06)),
            (AskTheme.accentText, rgb(29, 78, 216)),
            (AskTheme.launcherMetaText, rgb(69, 69, 69)),
            (AskTheme.launcherSelection, rgb(0, 0, 0, 0.10)),
            (AskTheme.launcherSelectionEdge, .clear),
            (AskTheme.launcherKeyword, rgb(0, 0, 0, 0.06)),
            (AskTheme.switchOnFill, rgb(37, 99, 235, 0.10)),
            (AskTheme.switchOnEdge, rgb(37, 99, 235, 0.20)),
            (AskTheme.privateTint, rgb(147, 51, 234)),
            (AskTheme.privateFill, rgb(147, 51, 234, 0.10)),
            (AskTheme.privateHeaderFill, rgb(147, 51, 234, 0.10)),
            (AskTheme.launcherShortcutFill, .white),
            (AskTheme.launcherShortcutEdge, rgb(15, 23, 42, 0.14)),
            (AskTheme.keycapSurface, .white),
            (AskTheme.noteQuestionSurface, .white),
            (AskTheme.userBubble, rgb(37, 99, 235, 0.08)),
            (AskTheme.userBubbleEdge, .clear)
        ]
        for (index, pair) in pairs.enumerated() {
            try expectColor(pair.0, pair.1, dark: false, context: "light token \(index)")
        }
    }

    @Test func `dark workspace tokens and neutral launcher palette`() throws {
        func grey(_ alpha: Double) -> Color {
            Color(nsColor: NSColor(calibratedWhite: 1, alpha: alpha))
        }
        func calibrated(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> Color {
            Color(nsColor: NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha))
        }
        let pairs: [(Color, Color)] = [
            (AskTheme.border, grey(0.10)), (AskTheme.separator, grey(0.07)),
            (AskTheme.launcherSeparator, grey(0.04)), (AskTheme.librarySeparator, grey(0.07)),
            (AskTheme.cardBorder, grey(0.10)), (AskTheme.accentText, calibrated(0.557, 0.741, 1)),
            (AskTheme.launcherMetaText, rgb(166, 166, 166)),
            (AskTheme.launcherSelection, rgb(50, 50, 50)),
            (AskTheme.launcherSelectionEdge, .clear),
            (AskTheme.launcherKeyword, rgb(56, 56, 56, 0.72)),
            (AskTheme.switchOnFill, calibrated(0.09, 0.55, 1, 0.22)),
            (AskTheme.switchOnEdge, calibrated(0.09, 0.55, 1, 0.35)),
            (AskTheme.privateTint, Color(nsColor: .systemPurple)),
            (AskTheme.privateFill, Color(nsColor: .systemPurple).opacity(0.13)),
            (AskTheme.privateHeaderFill, Color(nsColor: .systemPurple).opacity(0.12)),
            (AskTheme.launcherShortcutFill, .clear), (AskTheme.launcherShortcutEdge, grey(0.07)),
            (AskTheme.keycapSurface, AskTheme.hoverFill),
            (AskTheme.noteQuestionSurface, AskTheme.hoverFill.opacity(0.6)),
            (AskTheme.userBubble, AskTheme.accent.opacity(0.18)),
            (AskTheme.userBubbleEdge, AskTheme.accent.opacity(0.42))
        ]
        for (index, pair) in pairs.enumerated() {
            try expectColor(pair.0, pair.1, dark: true, context: "dark token \(index)")
        }
        #expect(AskGlassPlacement.floating.frost(dark: true) == 0.78)
        #expect(AskGlassPlacement.inWindow.frost(dark: true) == 0.45)
        #expect(AskGlassPlacement.menu.frost(dark: true) == 0.90)
    }

    @Test func `private colours render like the original system purple in dark`() async throws {
        let application = NSApplication.shared
        let appearance = application.appearance
        application.appearance = NSAppearance(named: .aqua)
        defer { application.appearance = appearance }
        let pairs: [(Color, Color)] = [
            (AskTheme.privateTint, Color(nsColor: .systemPurple)),
            (AskTheme.privateFill, Color(nsColor: .systemPurple).opacity(0.13)),
            (AskTheme.privateHeaderFill, Color(nsColor: .systemPurple).opacity(0.12))
        ]
        for (actual, expected) in pairs {
            let actualColor = try await render(actual.frame(width: 160, height: 60), style: .liquidGlass, dark: true)
            let expectedColor = try await render(expected.frame(width: 160, height: 60),
                                                 style: .liquidGlass, dark: true)
            #expect(abs(actualColor.redComponent - expectedColor.redComponent) < 0.002)
            #expect(abs(actualColor.greenComponent - expectedColor.greenComponent) < 0.002)
            #expect(abs(actualColor.blueComponent - expectedColor.blueComponent) < 0.002)
        }
    }

    @Test func `orb changes only its light palette`() throws {
        let light = [rgb(91, 141, 239), rgb(79, 70, 229), rgb(55, 48, 163),
                     rgb(79, 70, 229), rgb(91, 141, 239), rgb(91, 141, 239)]
        let dark: [Color] = [Color(red: 0.18, green: 0.42, blue: 1), Color(red: 0.55, green: 0.36, blue: 0.96),
                             Color(red: 1, green: 0.30, blue: 0.55), Color(red: 1, green: 0.70, blue: 0.28),
                             Color(red: 0.18, green: 0.90, blue: 0.84), Color(red: 0.18, green: 0.42, blue: 1)]
        #expect(AskConversationOrb.colors.count == dark.count)
        for index in dark.indices {
            try expectColor(AskConversationOrb.colors[index], light[index], dark: false)
            try expectColor(AskConversationOrb.colors[index], dark[index], dark: true)
        }
    }

    @Test(arguments: [InterfaceStyle.liquidGlass, .classic])
    func `library rows share the light selection and keep their dark style`(style: InterfaceStyle) async throws {
        let row = Color.clear.frame(width: 160, height: 60)
            .askNotesRow(selected: true, hovering: false, corner: 12)
        let light = try await render(row, style: style, dark: false)
        // Compare through the same renderer: AppKit converts the bitmap's working
        // colour space before returning sRGB, so raw channel arithmetic differs.
        let expected = try await render(AskTheme.launcherSelection.frame(width: 160, height: 60),
                                        style: style, dark: false)
        #expect(abs(light.redComponent - expected.redComponent) < 0.002)
        #expect(abs(light.blueComponent - expected.blueComponent) < 0.002)
        let dark = try await render(row, style: style, dark: true)
        let darkFill = try await render((style.usesGlass ? AskTheme.accent.opacity(0.18) : AskClassic.selection)
            .frame(width: 160, height: 60), style: style, dark: true)
        #expect(abs(dark.redComponent - darkFill.redComponent) < 0.002)
        #expect(abs(dark.blueComponent - darkFill.blueComponent) < 0.002)
        let shelf = Color.clear.frame(width: 160, height: 60)
            .askNotesRow(selected: true, hovering: false, corner: 12, sidebar: true)
        let lightShelf = try await render(shelf, style: style, dark: false)
        let darkShelf = try await render(shelf, style: style, dark: true)
        #expect(lightShelf.redComponent > 0.99 && lightShelf.blueComponent > 0.99)
        #expect(abs(darkShelf.blueComponent - darkFill.blueComponent) < 0.002)
        let hover = try await render(Color.clear.frame(width: 160, height: 60)
            .askNotesRow(selected: false, hovering: true, corner: 12), style: style, dark: false)
        #expect(hover.redComponent < 0.97)
        let idle = try await render(Color.clear.frame(width: 160, height: 60)
            .askNotesRow(selected: false, hovering: false, corner: 12), style: style, dark: false)
        #expect(idle.redComponent > 0.99)
    }

    @Test(arguments: [InterfaceStyle.liquidGlass, .classic])
    func `clipboard keycaps are white in light and keep the dark wash`(style: InterfaceStyle) async throws {
        let keycap = ClipboardKeycap(text: "").frame(width: 160, height: 60)
        let light = try await render(keycap, style: style, dark: false)
        #expect(light.redComponent > 0.99 && light.blueComponent > 0.99)
        let dark = try await render(keycap, style: style, dark: true)
        let original = try await render(Color.primary.opacity(0.1).frame(width: 160, height: 60),
                                        style: style, dark: true)
        #expect(abs(dark.redComponent - original.redComponent) < 0.002)
        #expect(abs(dark.blueComponent - original.blueComponent) < 0.002)
    }

    private struct HistorySelection: View {
        @Namespace private var selection
        var body: some View {
            AskHistoryRow(title: "", updatedAt: .distantPast, selected: true, busy: false,
                          selectionSpace: selection, onSelect: {}, onDelete: {})
                .frame(width: 160, height: 60)
        }
    }

    @Test(arguments: [InterfaceStyle.liquidGlass, .classic])
    func `history selection rises as a white card in light`(style: InterfaceStyle) async throws {
        let light = try await render(HistorySelection(), style: style, dark: false)
        #expect(light.redComponent > 0.99 && light.blueComponent > 0.99)
        let dark = try await render(HistorySelection(), style: style, dark: true)
        let expected = try await render((style.usesGlass ? AskTheme.accent.opacity(0.18) : AskClassic.selection)
            .frame(width: 160, height: 60), style: style, dark: true)
        // The existing dark glass row also has a faint tint shadow.
        #expect(abs(dark.redComponent - expected.redComponent) < 0.01)
        #expect(abs(dark.blueComponent - expected.blueComponent) < 0.01)
    }

    @Test(arguments: [InterfaceStyle.liquidGlass, .classic])
    func `content cards are white in light and retain their dark material`(style: InterfaceStyle) async throws {
        for elevated in [false, true] {
            let card = Color.clear.frame(width: 160, height: 60)
                .askContentCard(corner: 12, opaqueFill: AskTheme.glassFill, elevatedInLight: elevated)
            let light = try await render(card, style: style, dark: false)
            #expect(light.redComponent > 0.99 && light.blueComponent > 0.99)
            let dark = try await render(card, style: style, dark: true)
            let original = try await render(Color.clear.frame(width: 160, height: 60)
                .askInWindowGlass(corner: 12), style: style, dark: true)
            #expect(abs(dark.redComponent - original.redComponent) < 0.002)
            #expect(abs(dark.blueComponent - original.blueComponent) < 0.002)
        }
        let lightGroup = try await render(Color.clear.frame(width: 160, height: 60).askWordBookGroup(),
                                          style: style, dark: false)
        let darkGroup = try await render(Color.clear.frame(width: 160, height: 60).askWordBookGroup(),
                                         style: style, dark: true)
        #expect(lightGroup.redComponent > 0.99)
        #expect(darkGroup.redComponent < 0.01)
    }

    private func render(_ view: some View, style: InterfaceStyle, dark: Bool) async throws -> NSColor {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 60),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view
            .environment(\.interfaceStyle, style).environment(\.askGlassMaterialOverride, .opaque)
            .environment(\.colorScheme, dark ? .dark : .light).background(dark ? Color.black : Color.white))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }
}
