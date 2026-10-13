import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct FloatingPanelFidelityTests {
    @Test func splitChromeReservesItsGapAndAccommodatesMultilineEditors() {
        #expect(AskLauncherSpotlightLayout.headerHeight(editor: 32, style: .classic) == 52)
        #expect(AskLauncherSpotlightLayout.headerHeight(editor: 32, style: .liquidGlass) == 56)
        #expect(AskLauncherSpotlightLayout.headerHeight(editor: 148, style: .liquidGlass) == 164)
        #expect(AskLauncherSpotlightLayout.chromeAdjustment(editor: 32, style: .liquidGlass, collapsed: false) == 10)
        #expect(AskLauncherSpotlightLayout.chromeAdjustment(editor: 32, style: .liquidGlass, collapsed: true) == -2)
        #expect(AskLauncherSpotlightLayout.chromeAdjustment(editor: 32, style: .classic, collapsed: false) == -6)
    }

    @Test func clipboardModesStayEqualAndSeparateFromResults() async throws {
        let model = ClipboardPanelModel()
        model.reset(entries: [ClipboardTestSupport.entry(.text, text: "Text")])
        let view = ClipboardPanelView(model: model, focusRequest: 0)
            .environment(\.interfaceStyle, .liquidGlass)
            .environment(\.glassMaterialOverride, .opaque)
        try await TypefluxNavigationTestSupport.withWindow(view,
            size: ClipboardPanelView.size(showsPreview: false), nonactivating: true) { window, host in
            for category in ClipboardCategory.allCases {
                model.category = category
                try await TypefluxNavigationTestSupport.wait("five equal mode buttons", in: window, host: host) {
                    let modes = SettingsBehaviorTestSupport.elements(in: host).filter {
                        ($0.value("accessibilityIdentifier") as? String)?.hasPrefix("typeflux.spotlight.mode.") == true
                    }
                    return modes.count == 5 && modes.allSatisfy {
                        abs($0.frame.width - 56) < 1 && abs($0.frame.height - 56) < 1
                    }
                }
                let buttons = try ClipboardCategory.allCases.map {
                    try SettingsBehaviorTestSupport.button($0.title, in: host)
                }.sorted { $0.frame.minX < $1.frame.minX }
                for pair in zip(buttons, buttons.dropFirst()) {
                    #expect(pair.1.frame.minX - pair.0.frame.maxX >= 7)
                }
                let search = try #require(TypefluxNavigationTestSupport.searchField(in: host))
                let fieldFrame = window.convertToScreen(search.convert(search.bounds, to: nil))
                #expect(fieldFrame.maxX < buttons[0].frame.minX)
            }
            model.category = .all
            try await TypefluxNavigationTestSupport.wait("persistent quick paste hint", in: window, host: host) {
                SettingsBehaviorTestSupport.elements(in: host).contains { $0.text.contains("⌘1") }
            }
            #expect(SettingsBehaviorTestSupport.elements(in: host).contains {
                $0.value("accessibilityIdentifier") as? String == "clipboard.more"
            })
            #expect(!SettingsBehaviorTestSupport.contains(L("clipboard.action.pin"), in: host))
        }
    }

    @Test func launcherControlsShareTheModeDiameterAndAccessibilityFallbacks() async throws {
        let fixture = try AskTestFixture()
        defer {
            fixture.model.resetSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        for options in [TypefluxAccessibilityOptions(reduceTransparency: true),
                        TypefluxAccessibilityOptions(increasedContrast: true)] {
            let view = AskLauncherView(model: fixture.model, onDismiss: {})
                .environment(\.interfaceStyle, .liquidGlass)
                .environment(\.typefluxAccessibilityOptions, options)
                .environment(\.glassMaterialOverride, .liquidGlass)
            try await TypefluxNavigationTestSupport.withWindow(view,
                size: NSSize(width: 440, height: 440), nonactivating: true) { window, host in
                for identifier in ["ask.composer.voice", "ask.launcher.openChat"] {
                    let element = try #require(SettingsBehaviorTestSupport.elements(in: window).first {
                        $0.value("accessibilityIdentifier") as? String == identifier
                    })
                    #expect(abs(element.frame.width - 56) < 1)
                    #expect(abs(element.frame.height - 56) < 1)
                }
                #expect(!TypefluxNavigationTestSupport.descendants(of: host).contains {
                    $0 is NSVisualEffectView || NSStringFromClass(type(of: $0)).contains("NSGlassEffectView")
                })
            }
        }
    }

    @Test func hoveringAnotherHomeRowKeepsTheKeyboardSelection() async throws {
        var highlighted = 0
        let first = AskLauncherHome.Row(id: "first", title: "First", symbol: "doc", tint: .neutral,
                                        action: .ask("First"))
        let second = AskLauncherHome.Row(id: "second", title: "Second", symbol: "doc", tint: .neutral,
                                         action: .ask("Second"))
        let view = AskLauncherSuggestions(sections: [.recent(rows: [first, second])],
                                           highlighted: Binding(get: { highlighted }, set: { highlighted = $0 }),
                                           onPick: { _ in })
        try await TypefluxNavigationTestSupport.withWindow(view, size: NSSize(width: 440, height: 180)) {
            window, host in
            let target = try SettingsBehaviorTestSupport.button("Second", in: host)
            let point = window.convertPoint(fromScreen: NSPoint(x: target.frame.midX, y: target.frame.midY))
            var delivered = false
            for native in TypefluxNavigationTestSupport.descendants(of: host) {
                for area in native.trackingAreas {
                    let rect = area.options.contains(.inVisibleRect) ? native.visibleRect : area.rect
                    guard rect.contains(native.convert(point, from: nil)), let owner = area.owner as? NSResponder
                    else { continue }
                    owner.mouseEntered(with: FloatingPanelHoverEvent(area: area, point: point, window: window))
                    delivered = true
                }
            }
            #expect(delivered, "The second row must have an actual hover tracking area")
            await Task.yield()
            #expect(highlighted == 0, "Return must continue to target the row selected with the keyboard")
        }
    }
}

/// Supply the tracking area that SwiftUI reads, without moving the user's pointer.
private final class FloatingPanelHoverEvent: NSEvent {
    private let area: NSTrackingArea
    private let point: NSPoint
    private let targetWindowNumber: Int

    init(area: NSTrackingArea, point: NSPoint, window: NSWindow) {
        self.area = area
        self.point = point
        targetWindowNumber = window.windowNumber
        super.init()
    }

    required init?(coder: NSCoder) { nil }
    override var trackingArea: NSTrackingArea? { area }
    override var locationInWindow: NSPoint { point }
    override var windowNumber: Int { targetWindowNumber }
    override var type: NSEvent.EventType { .mouseEntered }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
