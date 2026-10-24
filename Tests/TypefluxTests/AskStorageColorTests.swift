import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// GUL-426: where a conversation is kept is marked by one quiet tint family (Sky, Sage,
/// Sand), only where it needs telling apart; the composer and send button stay neutral.
@Suite("Ask storage colours", .serialized, .exclusiveUIState)
@MainActor
struct AskStorageColorTests {
    /// A fixture with one of the user's own models, so a conversation can be kept on this Mac.
    private func fixture(signedIn: Bool = true) throws -> AskTestFixture {
        let defaults = try #require(UserDefaults(suiteName: "ask-storage-colour-" + UUID().uuidString))
        let profile = AskModelProfile(name: "My model", baseURL: "https://models.example/v1", model: "my-model")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "llm.model.profiles")
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        return try AskTestFixture(localOnly: !signedIn, modelLibrary: library)
    }

    private func resolve(_ color: Color, dark: Bool) throws -> NSColor {
        var result: NSColor?
        try #require(NSAppearance(named: dark ? .darkAqua : .aqua)).performAsCurrentDrawingAppearance {
            result = NSColor(color).usingColorSpace(.sRGB)
        }
        return try #require(result)
    }

    private func hex(_ color: Color, dark: Bool) throws -> UInt32 {
        let c = try resolve(color, dark: dark)
        func byte(_ v: CGFloat) -> UInt32 { UInt32((v * 255).rounded()) }
        return byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
    }

    private func luminance(_ c: NSColor) -> Double {
        func channel(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent)
            + 0.0722 * channel(c.blueComponent)
    }

    private func contrast(_ a: Color, _ b: Color, dark: Bool) throws -> Double {
        let x = luminance(try resolve(a, dark: dark)), y = luminance(try resolve(b, dark: dark))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private func fits<V: View>(_ view: V) -> CGSize {
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    // MARK: - Tokens

    @Test func theTintsUseTheSkySageAndSandFamily() throws {
        #expect(try hex(AskTheme.privateTint, dark: true) == 0x8CC9A7)
        #expect(try hex(AskTheme.privateTint, dark: false) == 0x2F7A57)
        #expect(try hex(AskTheme.temporaryTint, dark: true) == 0xE5B567)
        #expect(try hex(AskTheme.temporaryTint, dark: false) == 0x93600F)
        #expect(try hex(AskTheme.cloudTint, dark: false) == 0x1D4ED8)
        #expect(try hex(AskTheme.cloudTint, dark: true) == 0x8EBDFF)
        #expect(abs(try resolve(AskTheme.temporaryFill, dark: false).alphaComponent - 0.10) < 0.001)
        #expect(abs(try resolve(AskTheme.temporaryFill, dark: true).alphaComponent - 0.12) < 0.001)
        #expect(AskTheme.privateHeaderFill == AskTheme.privateFill)
        #expect(AskTheme.temporaryEdgeOpacity == 0.55)
    }

    @Test(arguments: [false, true])
    func everyTintIsReadableOnTheComposer(dark: Bool) throws {
        for tint in [AskTheme.cloudTint, AskTheme.privateTint, AskTheme.temporaryTint] {
            #expect(try contrast(tint, AskTheme.composerSurface, dark: dark) >= 4.5)
            #expect(try contrast(tint, AskTheme.surface, dark: dark) >= 4.5)
        }
    }

    @Test func theDarkTintsShareOneLightness() throws {
        let levels = try [AskTheme.cloudTint, AskTheme.privateTint, AskTheme.temporaryTint]
            .map { luminance(try resolve($0, dark: true)) }
        let brightest = try #require(levels.max()), dimmest = try #require(levels.min())
        #expect(brightest - dimmest < 0.06, "no storage kind should outshine the others: \(levels)")
    }

    @Test(arguments: [false, true])
    func theSendButtonIsANeutralHighContrastDrop(dark: Bool) throws {
        #expect(try contrast(AskTheme.sendFill, AskTheme.sendInk, dark: dark) >= 12)
        let fill = try resolve(AskTheme.sendFill, dark: dark)
        #expect(abs(fill.redComponent - fill.blueComponent) < 0.02, "the send fill carries no hue")
        #expect(try hex(AskTheme.sendFill, dark: dark) == (dark ? 0xF2F2F3 : 0x16171A))
    }

    // MARK: - What is marked

    @Test func onlyAStorageThatNeedsTellingApartIsMarked() {
        #expect(AskStorageKind.marked(.cloud, signedIn: true) == nil)
        #expect(AskStorageKind.marked(.cloud, signedIn: false) == nil)
        #expect(AskStorageKind.marked(.local, signedIn: true) == nil)
        #expect(AskStorageKind.marked(.local, signedIn: false) == nil, "signed out every chat is on this Mac")
        #expect(AskStorageKind.marked(.temporary, signedIn: true) == .temporary)
        #expect(AskStorageKind.marked(.temporary, signedIn: false) == .temporary)
    }

    @Test func theModelMarksTheComposersStorage() throws {
        let signedIn = try fixture()
        defer { signedIn.model.resetSession() }
        #expect(signedIn.model.markedStorage(launcher: false) == nil)
        signedIn.model.chooseStorage(.local, launcher: false)
        #expect(signedIn.model.markedStorage(launcher: false) == nil)
        signedIn.model.chooseStorage(.temporary, launcher: false)
        #expect(signedIn.model.markedStorage(launcher: false) == .temporary)

        let signedOut = try fixture(signedIn: false)
        defer { signedOut.model.resetSession() }
        #expect(signedOut.model.markedStorage(launcher: false) == nil)
        signedOut.model.chooseStorage(.temporary, launcher: false)
        #expect(signedOut.model.markedStorage(launcher: false) == .temporary)
    }

    @Test func storageTintsMarkOnlyWhatNeedsTellingApart() {
        #expect(AskLocalModeCard.tint(.cloud) == AskTheme.cloudTint)
    }

    // MARK: - Orb

    @Test func theOrbFollowsTheMarkedStorage() {
        #expect(AskOrbPalette(marked: nil) == .brand)
        #expect(AskOrbPalette(marked: .cloud) == .brand)
        #expect(AskOrbPalette(marked: .local) == .sage)
        #expect(AskOrbPalette(marked: .temporary) == .sand)
        #expect(AskOrbPalette.brand.colors == AskConversationOrb.colors)
        #expect(AskOrbPalette.brand.flowColors == AskConversationOrb.flowColors)
    }

    @Test(arguments: [AskOrbPalette.sage, .sand])
    func eachOrbPaletteWrapsSeamlessly(palette: AskOrbPalette) throws {
        let colors = palette.colors
        #expect(colors.count == AskConversationOrb.colors.count)
        #expect(palette.flowColors.count == colors.count * 2 - 1)
        let first = try #require(colors.first), last = try #require(colors.last)
        for dark in [false, true] {
            let start = try hex(first, dark: dark), end = try hex(last, dark: dark)
            #expect(start == end)
        }
        let hosting = NSHostingView(rootView: AskConversationOrb(size: 60, palette: palette))
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize == CGSize(width: 60, height: 60))
    }

    // MARK: - Surfaces

    @Test func theTemporaryTitleMarkStillRenders() {
        #expect(fits(AskStorageTitleGlyph(kind: .temporary)).width > 0)
    }

    // MARK: - Snapshots

    /// Writes the workspace kept on this Mac, signed in and out, when
    /// `TYPEFLUX_STORAGE_SNAPSHOTS` names a directory; otherwise it does nothing.
    @Test func renderStorageSurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_STORAGE_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        let size = NSSize(width: 1100, height: 720)

        let f = try fixture()
        defer { f.model.resetSession() }
        await f.api.seed(.init(id: "a", title: "讲讲这一屏在做什么", revision: 1, updatedAt: Date(), messages: []))
        await f.model.refreshHistory()
        f.model.chooseStorage(.local, launcher: false)
        f.model.draft.text = "帮我实现一个俄罗斯方块小游戏"
        for dark in [false, true] {
            try await render(AskConversationView(model: f.model), size: size, dark: dark,
                             file: root.appendingPathComponent("local-new-\(dark ? "dark" : "light").png"))
        }
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.run?.status == "completed" }
        for dark in [false, true] {
            try await render(AskConversationView(model: f.model), size: size, dark: dark,
                             file: root.appendingPathComponent("local-chat-\(dark ? "dark" : "light").png"))
        }

        let signedOut = try fixture(signedIn: false)
        defer { signedOut.model.resetSession() }
        for dark in [false, true] {
            try await render(AskConversationView(model: signedOut.model), size: size, dark: dark,
                             file: root.appendingPathComponent("signed-out-new-\(dark ? "dark" : "light").png"))
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, dark: Bool, file: URL) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view.environment(\.askGlassMaterialOverride, .opaque)
            .frame(width: size.width, height: size.height, alignment: .top))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(500))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: file)
        #expect(png.count > 2000)
    }
}
