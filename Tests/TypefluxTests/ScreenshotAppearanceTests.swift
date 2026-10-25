import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Capture interface appearance", .serialized, .exclusiveUIState)
@MainActor
struct ScreenshotAppearanceTests {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func window(_ view: some View, dark: Bool) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 760),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: view.frame(width: 1000, height: 760))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    @Test func screenshotAndRecordingChromeUseTheSelectedMaterial() async throws {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *) else { return }
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.setup()
        defer { fixture.model.cancel() }
        let beauty = ScreenshotBeautificationPreview(source: ScreenshotSnapshotSupport.sampleScreen(),
                                                      scale: 1, settings: ScreenshotBeautification())
        let actions = ScrollCaptureActions(togglePause: {}, undo: {}, cancel: {}, finish: {},
                                           openAccessibilitySettings: {})
        var state = ScreenshotEditorToolbarModel.State()
        state.optionsTool = .rect
        state.showsOptions = true
        state.showsColor = true
        state.showsColorPanel = true
        state.showsMoreMenu = true
        let surfaces: [(String, AnyView)] = [
            ("annotation toolbar and menus", AnyView(ScreenshotEditorToolbar(state: state) { _ in })),
            ("pinned image toolbar", AnyView(ScreenshotPinBar(state: .init()) { _ in })),
            ("scrolling toolbar", AnyView(ScrollCaptureBar(state: .init(), actions: actions))),
            ("sensitive information", AnyView(ScreenshotSensitiveInfoPanel(state: .init(rows: [])) { _ in })),
            ("screenshot toast", AnyView(ScreenshotToastView(content: .init(message: "Copied", symbol: "checkmark"),
                                                            onReveal: {}))),
            ("beautification", AnyView(ScreenshotBeautificationView(model: beauty, cancel: {}, apply: {}))),
            ("recording toolbar and hints", AnyView(ScreenRecordingToolbar(model: fixture.model, close: {},
                                                                          chooseDirectory: {}))),
            ("recording options", AnyView(ScreenRecordingOptionsPopover(model: fixture.model, chooseDirectory: {}))),
            ("recording capsule", AnyView(ScreenRecordingCapsule(model: fixture.model, close: {})))
        ]
        for style in InterfaceStyle.allCases {
            for dark in [false, true] {
                for (name, surface) in surfaces {
                    let window = window(surface.environment(\.interfaceStyle, style)
                        .environment(\.colorScheme, dark ? .dark : .light), dark: dark)
                    defer { window.close() }
                    try await Task.sleep(for: .milliseconds(40))
                    let views = descendants(try #require(window.contentView))
                    let blur = views.compactMap { $0 as? NSVisualEffectView }
                    let glass = views.compactMap { $0 as? NSGlassEffectView }
                    switch style {
                    case .classic:
                        #expect(blur.isEmpty && glass.isEmpty, "\(name) retains glass in Classic")
                    case .frosted:
                        #expect(blur.contains { $0.material == .hudWindow }, "\(name) lacks the frosted material")
                    case .liquidGlass:
                        #expect(blur.isEmpty && !glass.isEmpty, "\(name) does not use native Liquid Glass")
                    }
                }
            }
        }
        await fixture.clean()
        #endif
    }

    @Test func independentHostingRootsFollowLiveStyleAndIntensityChanges() async throws {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *) else { return }
        let name = "capture-appearance-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        var observed: [(InterfaceStyle, Double)] = []
        let window = window(VStack {
            ScreenshotEditorToolbar(state: .init()) { _ in }
            Probe { observed.append(($0, $1)) }
        }.screenshotAppearance(settings: settings), dark: true)
        defer { window.close() }
        for style in [InterfaceStyle.frosted, .classic, .liquidGlass] {
            settings.interfaceStyle = style
            settings.liquidGlassIntensity = style == .frosted ? 0.4 : 0.9
            try await SettingsBehaviorTestSupport.wait {
                window.contentView?.layoutSubtreeIfNeeded()
                return observed.last?.0 == style && observed.last?.1 == settings.liquidGlassIntensity
            }
            window.contentView?.layoutSubtreeIfNeeded()
            let views = descendants(try #require(window.contentView))
            let blur = views.compactMap { $0 as? NSVisualEffectView }
            let glass = views.compactMap { $0 as? NSGlassEffectView }
            if style == .classic { #expect(blur.isEmpty && glass.isEmpty) }
            if style == .liquidGlass { #expect(blur.isEmpty && !glass.isEmpty) }
            if style == .frosted {
                #expect(blur.contains { $0.material == .hudWindow && $0.blendingMode == .withinWindow },
                        "The screenshot toolbar must frost the frozen image within its overlay")
            }
        }
        #endif
    }

    @Test func captureChromeHonorsOpaqueAccessibilityFallbacks() async throws {
        for style in InterfaceStyle.allCases {
            let window = window(VStack {
                ScreenshotEditorToolbar(state: .init()) { _ in }
                ScreenshotSensitiveInfoPanel(state: .init(rows: [])) { _ in }
                ScreenshotToastView(content: .init(message: "Saved", symbol: "checkmark"), onReveal: {})
            }.environment(\.interfaceStyle, style).environment(\.askGlassMaterialOverride, .opaque), dark: false)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(40))
            let views = descendants(try #require(window.contentView))
            #expect(views.allSatisfy { !($0 is NSVisualEffectView) })
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) { #expect(views.allSatisfy { !($0 is NSGlassEffectView) }) }
            #endif
        }
    }

    private struct Probe: View {
        @Environment(\.interfaceStyle) private var style
        @Environment(\.liquidGlassIntensity) private var intensity
        var report: (InterfaceStyle, Double) -> Void
        var body: some View {
            // Read the complete environment atomically when SwiftUI evaluates the
            // native root, independent of appearance callbacks for clear views.
            let _ = report(style, intensity.value)
            Color.clear.frame(height: 1)
        }
    }
}
