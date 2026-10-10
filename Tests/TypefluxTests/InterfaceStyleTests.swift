import AppKit
import Combine
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Interface style", .serialized, .exclusiveUIState)
@MainActor
struct InterfaceStyleTests {
    private func store() -> (SettingsStore, UserDefaults) {
        let suite = "interface-style-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (SettingsStore(defaults: defaults), defaults)
    }

    // MARK: - Materials

    @Test func classicIsOpaqueOnEverySystem() {
        for supports in [true, false] {
            for reduce in [true, false] {
                #expect(AskGlassMaterial.resolve(reduceTransparency: reduce, style: .classic,
                                                 supportsLiquidGlass: supports) == .opaque)
            }
        }
        #expect(AskGlassMaterial.resolve(reduceTransparency: false, style: .liquidGlass,
                                         supportsLiquidGlass: true) == .liquidGlass)
    }

    @Test func onlyLiquidGlassUsesGlass() {
        #expect(InterfaceStyle.liquidGlass.usesGlass)
        #expect(!InterfaceStyle.classic.usesGlass)
    }

    @Test func classicSurfacesOnlyShadowWhatFloats() {
        #expect(AskInWindowGlass.elevation(.panel, style: .classic) == nil)
        #expect(AskInWindowGlass.elevation(.control, style: .classic) == nil)
        #expect(AskInWindowGlass.elevation(.popover, style: .classic) == .popover)
        #expect(AskInWindowGlass.elevation(nil, style: .classic) == nil)
        for elevation in [AskElevation.panel, .control, .popover] {
            #expect(AskInWindowGlass.elevation(elevation, style: .liquidGlass) == elevation)
        }
    }

    // MARK: - Geometry

    @Test func glassMetricsKeepTheDesignBoardValues() {
        let glass = InterfaceStyle.liquidGlass.ask
        #expect(glass.sidebarRowHeight == 38)
        #expect(glass.sidebarRowCorner == AskMetrics.sidebarRowCorner)
        #expect(glass.composerCorner == 28)
        #expect(glass.suggestionCorner == 18)
        #expect(glass.paletteCorner == AskMetrics.paletteCorner)
        #expect(glass.headerChipHeight == AskMetrics.headerCapsuleHeight)
    }

    @Test func classicIsTighterEverywhere() {
        let glass = AskStyleMetrics.liquidGlass, classic = AskStyleMetrics.classic
        #expect(InterfaceStyle.classic.ask == classic)
        let pairs: [(CGFloat, CGFloat)] = [
            (classic.sidebarRowHeight, glass.sidebarRowHeight), (classic.sidebarRowCorner, glass.sidebarRowCorner),
            (classic.searchFieldHeight, glass.searchFieldHeight), (classic.searchFieldCorner, glass.searchFieldCorner),
            (classic.filterCorner, glass.filterCorner), (classic.suggestionCorner, glass.suggestionCorner),
            (classic.composerCorner, glass.composerCorner), (classic.paletteCorner, glass.paletteCorner),
            (classic.menuCorner, glass.menuCorner), (classic.hoverCardCorner, glass.hoverCardCorner),
            (classic.menuRowCorner, glass.menuRowCorner), (classic.headerChipHeight, glass.headerChipHeight)
        ]
        for (flat, round) in pairs { #expect(flat < round) }
        // The filter's thumb sits 2pt inside its track.
        #expect(classic.filterCorner - 2 > 0)
    }

    @Test func iconButtonsWashAsCapsulesOnGlassAndSquaresInClassic() {
        #expect(InterfaceStyle.liquidGlass.controlShape(height: 28).cornerSize.width == 14)
        #expect(InterfaceStyle.classic.controlShape(height: 28).cornerSize.width == 6)
    }

    @Test func classicComposerIsASolidCardAndTheLauncherKeepsItsShape() {
        let workspace = AskComposerChrome.of(launcher: false, style: .classic)
        #expect(workspace.corner == AskStyleMetrics.classic.composerCorner)
        #expect(workspace.fill == AskClassic.card)
        #expect(workspace.idleBorder == AskClassic.cardBorder)
        #expect(workspace.placement == .inWindow)
        #expect(AskComposerChrome.of(launcher: false, style: .liquidGlass) == .workspace)
        #expect(AskComposerChrome.of(launcher: false) == .workspace)
        #expect(AskComposerChrome.of(launcher: true, style: .classic) == .launcher)
        // The classic card has the glass card's insets, so text never moves between styles.
        #expect(workspace.horizontalInset == AskComposerChrome.workspace.horizontalInset)
        #expect(workspace.footerHeight == AskComposerChrome.workspace.footerHeight)
    }

    @Test func menuAndHoverCardCornersFollowTheStyle() {
        #expect(AskGlassCardSurface<EmptyView>.corner(.menu, style: .classic) == 10)
        #expect(AskGlassCardSurface<EmptyView>.corner(.hoverCard, style: .classic) == 8)
        #expect(AskGlassCardSurface<EmptyView>.corner(.hoverCard, style: .liquidGlass) == 14)
    }

    // MARK: - Following settings

    @Test func observerStartsFromTheStoredStyle() {
        let (settings, defaults) = store()
        defaults.set(InterfaceStyle.classic.rawValue, forKey: "ui.overlayStyle")
        #expect(InterfaceStyleObserver(settings: settings).style == .classic)
    }

    @Test func observerFollowsChangesFromAnyStore() {
        let (settings, defaults) = store()
        let center = NotificationCenter()
        let observer = InterfaceStyleObserver(settings: settings, center: center)
        #expect(observer.style == .liquidGlass)
        // Another store over the same defaults writes the change, as Settings does.
        defaults.set(InterfaceStyle.classic.rawValue, forKey: "ui.overlayStyle")
        center.post(name: .interfaceStyleDidChange, object: SettingsStore(defaults: defaults))
        #expect(observer.style == .classic)
        defaults.set(InterfaceStyle.liquidGlass.rawValue, forKey: "ui.overlayStyle")
        center.post(name: .interfaceStyleDidChange, object: nil)
        #expect(observer.style == .liquidGlass)
    }

    @Test func observerPublishesOnlyRealChanges() {
        let (settings, _) = store()
        let observer = InterfaceStyleObserver(settings: settings)
        var changes = 0
        let subscription = observer.objectWillChange.sink { changes += 1 }
        observer.refresh()
        #expect(changes == 0)
        settings.interfaceStyle = .classic
        #expect(observer.style == .classic)
        #expect(changes == 1)
        subscription.cancel()
    }

    @Test func releasedObserverStopsListening() {
        let (settings, _) = store()
        let center = NotificationCenter()
        var observer: InterfaceStyleObserver? = InterfaceStyleObserver(settings: settings, center: center)
        weak var released = observer
        observer = nil
        #expect(released == nil)
        // Nothing is left to receive this; it must not crash.
        center.post(name: .interfaceStyleDidChange, object: nil)
    }

    @Test func storedKeyIsUnchangedSoEarlierChoicesCarryOver() {
        let (settings, defaults) = store()
        settings.interfaceStyle = .classic
        #expect(defaults.string(forKey: "ui.overlayStyle") == "classic")
        #expect(InterfaceStyle(rawValue: "liquidGlass") == .liquidGlass)
    }

    @Test func rootModifierHandsTheStyleToItsContent() async throws {
        let (settings, _) = store()
        settings.interfaceStyle = .classic
        let observer = InterfaceStyleObserver(settings: settings)
        var seen: [InterfaceStyle] = []
        let hosting = NSHostingView(rootView: StyleProbe { seen.append($0) }.interfaceStyle(following: observer))
        hosting.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        hosting.layoutSubtreeIfNeeded()
        #expect(seen.last == .classic)
        settings.interfaceStyle = .liquidGlass
        for _ in 0 ..< 50 where seen.last != .liquidGlass {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(seen.last == .liquidGlass)
    }

    @Test func floatingCardsTakeTheStyleOfTheirAnchor() throws {
        let holder = AskHoverAnchor.Holder()
        let hosting = NSHostingView(rootView: AskHoverAnchor(holder: holder).environment(\.interfaceStyle, .classic))
        hosting.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        hosting.layoutSubtreeIfNeeded()
        let anchor = try #require(holder.view)
        #expect(AskHoverAnchor.style(of: anchor) == .classic)
        hosting.rootView = AskHoverAnchor(holder: holder).environment(\.interfaceStyle, .liquidGlass)
        hosting.layoutSubtreeIfNeeded()
        #expect(AskHoverAnchor.style(of: anchor) == .liquidGlass)
        // A view that is not an anchor keeps the default look.
        #expect(AskHoverAnchor.style(of: NSView()) == .liquidGlass)
    }

    // MARK: - Side panels

    /// The classic sidebar is flush with the window edge; the glass panel is inset.
    @Test func classicSidePanelsSitFlushWithTheWindowEdge() throws {
        func leadingPixel(_ style: InterfaceStyle) throws -> NSColor {
            let view = Color.clear.frame(width: 120, height: 80)
                .askSidePanel(edge: .leading, glassFill: .white, classicFill: Color(red: 1, green: 0, blue: 0),
                              glassInset: [.leading, .top, .bottom])
                .environment(\.interfaceStyle, style)
                .environment(\.askGlassMaterialOverride, .opaque)
                .frame(width: 140, height: 100, alignment: .leading)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = CGRect(x: 0, y: 0, width: 140, height: 100)
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            return try #require(bitmap.colorAt(x: 2, y: bitmap.pixelsHigh / 2))
        }
        let classic = try leadingPixel(.classic)
        #expect(classic.alphaComponent > 0.99)
        #expect(classic.redComponent > 0.9 && classic.greenComponent < 0.1)
        // Only the glass panel's soft shadow reaches into its inset, never its fill.
        let glass = try leadingPixel(.liquidGlass)
        #expect(glass.alphaComponent < 0.5)
    }

    // MARK: - Settings copy

    private func strings(_ language: String) throws -> [String: String] {
        let path = try #require(Bundle.module.path(forResource: language, ofType: "lproj"))
        let url = URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    @Test func settingsNameTheGlobalStyleInEveryLanguage() throws {
        let expected = ["zh-Hans": ("界面风格", "经典"), "zh-Hant": ("介面風格", "經典"),
                        "en": ("Interface style", "Classic"), "ja": ("インターフェーススタイル", "クラシック"),
                        "ko": ("인터페이스 스타일", "클래식")]
        for (language, (title, classic)) in expected {
            let table = try strings(language)
            #expect(table["settings.interfaceStyle.title"] == title, "\(language)")
            #expect(table["interfaceStyle.classic"] == classic, "\(language)")
            #expect(table["interfaceStyle.liquidGlass"] == "Liquid Glass", "\(language)")
            #expect(table["settings.interfaceStyle.subtitle"]?.isEmpty == false, "\(language)")
            #expect(!table.keys.contains { $0.contains("overlayStyle") }, "\(language) keeps a stale key")
            // The old name never shows, not even as a "formerly" note.
            for old in ["胶囊样式", "膠囊樣式", "Capsule style", "カプセルスタイル", "캡슐 스타일", "原"] {
                #expect(table["settings.interfaceStyle.title"]?.contains(old) == false, "\(language): \(old)")
            }
        }
    }
}

private struct StyleProbe: View {
    var report: (InterfaceStyle) -> Void
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        Color.clear.onAppear { report(style) }.onChange(of: style) { report($0) }
    }
}
