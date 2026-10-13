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

    @Test func lightWorkspaceTokensAndNeutralLauncherPalette() throws {
        let pairs: [(Color, Color)] = [
            (TypefluxColor.separator.color, TypefluxColor.separator.color),
            (TypefluxColor.separator.color, TypefluxColor.separator.color),
            (LegacyAskPalette.launcherSeparator, rgb(15, 23, 42, 0.08)),
            (TypefluxColor.separator.color, TypefluxColor.separator.color),
            (TypefluxColor.separator.color, TypefluxColor.separator.color),
            (TypefluxColor.accent.color, TypefluxColor.accent.color),
            (LegacyAskPalette.launcherMetaText, rgb(69, 69, 69)),
            (LegacyAskPalette.launcherSelection, rgb(0, 0, 0, 0.10)),
            (LegacyAskPalette.launcherSelectionEdge, .clear),
            (LegacyAskPalette.launcherKeyword, rgb(0, 0, 0, 0.06)),
            (LegacyAskPalette.switchOnFill, rgb(37, 99, 235, 0.10)),
            (LegacyAskPalette.switchOnEdge, rgb(37, 99, 235, 0.20)),
            (Color(nsColor: .systemPurple), Color(nsColor: .systemPurple)),
            (LegacyAskPalette.privateFill, rgb(147, 51, 234, 0.10)),
            (LegacyAskPalette.privateHeaderFill, rgb(147, 51, 234, 0.10)),
            (LegacyAskPalette.launcherShortcutFill, .white),
            (LegacyAskPalette.launcherShortcutEdge, rgb(15, 23, 42, 0.14)),
            (LegacyAskPalette.keycapSurface, .white),
            (LegacyAskPalette.noteQuestionSurface, .white),
            (TypefluxColor.controlBackground.color, TypefluxColor.controlBackground.color),
            (TypefluxColor.separator.color, TypefluxColor.separator.color)
        ]
        for (index, pair) in pairs.enumerated() {
            try expectColor(pair.0, pair.1, dark: false, context: "light token \(index)")
        }
    }

    @Test func darkWorkspaceTokensAndNeutralLauncherPalette() throws {
        func grey(_ alpha: Double) -> Color {
            Color(nsColor: NSColor(calibratedWhite: 1, alpha: alpha))
        }
        func calibrated(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> Color {
            Color(nsColor: NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha))
        }
        let pairs: [(Color, Color)] = [
            (TypefluxColor.separator.color, TypefluxColor.separator.color), (TypefluxColor.separator.color,
                                                                             TypefluxColor.separator.color),
            (LegacyAskPalette.launcherSeparator, grey(0.04)), (TypefluxColor.separator.color,
                                                               TypefluxColor.separator.color),
            (TypefluxColor.separator.color, TypefluxColor.separator.color), (TypefluxColor.accent.color,
                                                                             TypefluxColor.accent.color),
            (LegacyAskPalette.launcherMetaText, rgb(166, 166, 166)),
            (LegacyAskPalette.launcherSelection, rgb(50, 50, 50)),
            (LegacyAskPalette.launcherSelectionEdge, .clear),
            (LegacyAskPalette.launcherKeyword, rgb(56, 56, 56, 0.72)),
            (LegacyAskPalette.switchOnFill, calibrated(0.09, 0.55, 1, 0.22)),
            (LegacyAskPalette.switchOnEdge, calibrated(0.09, 0.55, 1, 0.35)),
            (Color(nsColor: .systemPurple), Color(nsColor: .systemPurple)),
            (LegacyAskPalette.privateFill, Color(nsColor: .systemPurple).opacity(0.13)),
            (LegacyAskPalette.privateHeaderFill, Color(nsColor: .systemPurple).opacity(0.12)),
            (LegacyAskPalette.launcherShortcutFill, .clear), (LegacyAskPalette.launcherShortcutEdge, grey(0.07)),
            (LegacyAskPalette.keycapSurface, LegacyAskPalette.hoverFill),
            (LegacyAskPalette.noteQuestionSurface, LegacyAskPalette.hoverFill.opacity(0.6)),
            (TypefluxColor.controlBackground.color, TypefluxColor.controlBackground.color),
            (TypefluxColor.separator.color, TypefluxColor.separator.color)
        ]
        for (index, pair) in pairs.enumerated() {
            try expectColor(pair.0, pair.1, dark: true, context: "dark token \(index)")
        }
        #expect(AskGlassPlacement.floating.frost(dark: true) == 0.78)
        #expect(AskGlassPlacement.inWindow.frost(dark: true) == 0.45)
        #expect(AskGlassPlacement.menu.frost(dark: true) == 0.90)
    }

    @Test func privateColoursRenderLikeTheOriginalSystemPurpleInDark() async throws {
        let application = NSApplication.shared
        let appearance = application.appearance
        application.appearance = NSAppearance(named: .aqua)
        defer { application.appearance = appearance }
        let pairs: [(Color, Color)] = [
            (Color(nsColor: .systemPurple), Color(nsColor: .systemPurple)),
            (LegacyAskPalette.privateFill, Color(nsColor: .systemPurple).opacity(0.13)),
            (LegacyAskPalette.privateHeaderFill, Color(nsColor: .systemPurple).opacity(0.12))
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

    @Test func orbChangesOnlyItsLightPalette() throws {
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
    func `studio sidebar owns its selected and idle backgrounds`(style: InterfaceStyle) async throws {
        let row = Color.clear.frame(width: 160, height: 60)
            .modifier(StudioSidebarRowBackground(selected: true, corner: 12))
        for dark in [false, true] {
            let selected = try await render(row, style: style, dark: dark)
            let fill = dark ? (style.usesGlass ? TypefluxColor.accent.color.opacity(0.18) : AskClassic.selection)
                : TypefluxColor.selection.color.opacity(0.12)
            // Compare through the renderer so both samples use the same bitmap colour space.
            let expected = try await render(fill.frame(width: 160, height: 60), style: style, dark: dark)
            #expect(abs(selected.redComponent - expected.redComponent) < 0.002)
            #expect(abs(selected.greenComponent - expected.greenComponent) < 0.002)
            #expect(abs(selected.blueComponent - expected.blueComponent) < 0.002)
            let idle = try await render(Color.clear.frame(width: 160, height: 60)
                .modifier(StudioSidebarRowBackground(selected: false, corner: 12)), style: style, dark: dark)
            let canvas = try await render(Color.clear.frame(width: 160, height: 60), style: style, dark: dark)
            #expect(abs(idle.redComponent - canvas.redComponent) < 0.002)
            #expect(abs(idle.greenComponent - canvas.greenComponent) < 0.002)
            #expect(abs(idle.blueComponent - canvas.blueComponent) < 0.002)
        }
    }

    @Test(arguments: [InterfaceStyle.liquidGlass, .classic])
    func clipboardKeycapsAreWhiteInLightAndKeepTheDarkWash(style: InterfaceStyle) async throws {
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
    func historySelectionUsesTheSystemSelectionInBothAppearances(style: InterfaceStyle) async throws {
        for dark in [false, true] {
            let actual = try await render(HistorySelection(), style: style, dark: dark)
            let expected = try await render(TypefluxColor.selection.color.frame(width: 160, height: 60),
                                            style: style, dark: dark)
            #expect(abs(actual.redComponent - expected.redComponent) < 0.002)
            #expect(abs(actual.greenComponent - expected.greenComponent) < 0.002)
            #expect(abs(actual.blueComponent - expected.blueComponent) < 0.002)
            #expect(abs(actual.alphaComponent - expected.alphaComponent) < 0.002)
        }
    }

    @Test(arguments: [InterfaceStyle.liquidGlass, .classic])
    func contentCardsAreWhiteInLightAndRetainTheirDarkMaterial(style: InterfaceStyle) async throws {
        for elevated in [false, true] {
            let card = Color.clear.frame(width: 160, height: 60)
                .askContentCard(corner: 12, opaqueFill: LegacyAskPalette.glassFill, elevatedInLight: elevated)
            let light = try await render(card, style: style, dark: false)
            #expect(light.redComponent > 0.99 && light.blueComponent > 0.99)
            let dark = try await render(card, style: style, dark: true)
            let original = try await render(Color.clear.frame(width: 160, height: 60)
                .askInWindowGlass(corner: 12), style: style, dark: true)
            #expect(abs(dark.redComponent - original.redComponent) < 0.002)
            #expect(abs(dark.blueComponent - original.blueComponent) < 0.002)
        }
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
