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

    @Test(arguments: [GlassMaterial.opaque, .liquidGlass])
    func clipboardModesStayEqualAndSeparateFromResults(_ material: GlassMaterial) async throws {
        let model = ClipboardPanelModel()
        model.reset(entries: [ClipboardTestSupport.entry(.text, text: "Text")])
        var moreRequests = 0
        model.onShowActions = { moreRequests += 1 }
        let view = ClipboardPanelView(model: model, focusRequest: 0)
            .environment(\.interfaceStyle, .liquidGlass)
            .environment(\.glassMaterialOverride, material)
        try await TypefluxNavigationTestSupport.withWindow(view,
            size: ClipboardPanelView.size(showsPreview: false, style: .liquidGlass),
            nonactivating: true) { window, host in
            #expect(window.frame.width == 680)
            #expect(host.bounds.width == 680)
            @MainActor func modeButtons() -> [SettingsBehaviorTestSupport.Element] {
                SettingsBehaviorTestSupport.elements(in: host).filter {
                    ($0.value("accessibilityIdentifier") as? String)?.hasPrefix("typeflux.spotlight.mode.") == true
                        && ["AXButton", "AXRadioButton"].contains($0.role)
                }
            }
            for category in ClipboardCategory.allCases {
                model.category = category
                try await TypefluxNavigationTestSupport.wait("five equal mode buttons", in: window, host: host,
                    diagnostics: {
                        modeButtons().map { "\($0.label): \($0.frame)" }.joined(separator: "; ")
                    }, until: {
                        let modes = modeButtons()
                        return modes.count == 5 && modes.allSatisfy {
                            abs($0.frame.width - 56) < 1 && abs($0.frame.height - 56) < 1
                        }
                    })
                let buttons = try ClipboardCategory.allCases.map {
                    try SettingsBehaviorTestSupport.button($0.title, in: host)
                }.sorted { $0.frame.minX < $1.frame.minX }
                for pair in zip(buttons, buttons.dropFirst()) {
                    #expect(pair.1.frame.minX - pair.0.frame.maxX >= 7)
                }
                let search = try #require(TypefluxNavigationTestSupport.searchField(in: host))
                let fieldFrame = window.convertToScreen(search.convert(search.bounds, to: nil))
                #expect(search.focusRingType == .none)
                #expect(fieldFrame.maxX < buttons[0].frame.minX)
                let viewport = window.convertToScreen(host.convert(host.bounds, to: nil))
                #expect(buttons[0].frame.minX > viewport.minX)
                #expect(try #require(buttons.last).frame.maxX <= viewport.maxX - 7)
                #expect(buttons[0].frame.maxY <= viewport.maxY - 7)
                expectModeBackgrounds(buttons, material: material, in: host, window: window)
            }
            model.category = .all
            try await TypefluxNavigationTestSupport.wait("persistent quick paste hint", in: window, host: host) {
                SettingsBehaviorTestSupport.elements(in: host).contains { $0.text.contains("⌘1") }
            }
            let more = try #require(SettingsBehaviorTestSupport.elements(in: host).first {
                $0.value("accessibilityIdentifier") as? String == "clipboard.more"
            })
            #expect(more.role == NSAccessibility.Role.button.rawValue)
            #expect(more.label == L("clipboard.toolbar.more"))
            try more.press()
            #expect(moreRequests == 1)
            #expect(!SettingsBehaviorTestSupport.contains(L("clipboard.action.pin"), in: host))
        }
    }

    private func expectModeBackgrounds(_ buttons: [SettingsBehaviorTestSupport.Element], material: GlassMaterial,
                                       in host: NSView, window: NSWindow) {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *), material == .liquidGlass {
                let diameter = TypefluxControlHeight.spotlightModeButton.value(for: .liquidGlass)
                let backgrounds = TypefluxNavigationTestSupport.descendants(of: host)
                    .compactMap { $0 as? NSGlassEffectView }.filter {
                        abs($0.bounds.width - diameter) < 1 && abs($0.bounds.height - diameter) < 1
                    }
                #expect(backgrounds.count == buttons.count, "Every mode needs its own complete glass circle")
                for button in buttons {
                    let background = backgrounds.first {
                        let frame = window.convertToScreen($0.convert($0.bounds, to: nil))
                        return abs(frame.minX - button.frame.minX) < 1 && abs(frame.minY - button.frame.minY) < 1
                    }
                    #expect(background != nil, "Missing material behind \(button.label)")
                    if let background {
                        #expect(background.visibleRect.width >= diameter - 1)
                        #expect(background.visibleRect.height >= diameter - 1)
                        #expect(background.cornerRadius == diameter / 2)
                    }
                }
            }
        #endif
    }

    @Test func overflowFitsWholeChipsAndTracksKeyboardSelection() {
        #expect(AskLauncherKeywordLayout.fitting(widths: [100, 100, 100, 100, 100],
                                                availableWidth: 250, spacing: 6) == [0, 1])
        #expect(AskLauncherKeywordLayout.fitting(widths: [100, 100, 100, 100, 100],
                                                availableWidth: 250, spacing: 6, selected: 3) == [2, 3])
        #expect(AskLauncherKeywordLayout.fitting(widths: [80, 90], availableWidth: 180, spacing: 6) == [0, 1])
        #expect(AskLauncherKeywordLayout.fitting(widths: [400], availableWidth: 200, spacing: 6).isEmpty)
        #expect(AskLauncherKeywordLayout.fitting(widths: [], availableWidth: 250, spacing: 6).isEmpty)
        #expect(AskLauncherKeywordLayout.fitting(widths: [100], availableWidth: -1, spacing: 6).isEmpty)
    }

    @Test func nativeMenuTrackingSuspendsHomeKeysAndReleasesItsObservers() async throws {
        let monitor = AskLauncherHomeKeyMonitor.MonitorView()
        try await TypefluxNavigationTestSupport.withWindow(Color.clear) { _, host in
            host.addSubview(monitor)
            let menu = NSMenu()
            let submenu = NSMenu()
            #expect(monitor.capturesHomeKeys)
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: submenu)
            #expect(!monitor.capturesHomeKeys)
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: submenu)
            #expect(!monitor.capturesHomeKeys)
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
            #expect(monitor.capturesHomeKeys)
            monitor.removeFromSuperview()
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            #expect(monitor.capturesHomeKeys, "Detached monitors must stop observing native menus")
        }
    }

    @Test func narrowKeywordRowOffersOverflowAndKeepsItsButtonsInsideTheViewport() async throws {
        let keywords = AskOpenChatPlugin.keywords
        let keyword = try #require(keywords.first)
        let chips = (0 ..< 5).map { index in
            var value = keyword
            value.keyword = "chat\(index)"
            return AskLauncherHome.Chip(keyword: value, title: "Long conversation keyword \(index)", symbol: "bubble.left")
        }
        let view = AskLauncherSuggestions(sections: [.keywords(chips: chips, teaching: true)],
                                           highlighted: .constant(0), onPick: { _ in })
        try await TypefluxNavigationTestSupport.withWindow(view, size: NSSize(width: 440, height: 100)) { window, host in
            let more = try #require(SettingsBehaviorTestSupport.elements(in: window).first {
                $0.value("accessibilityIdentifier") as? String == "ask.launcher.keywords.more"
            })
            let viewport = window.convertToScreen(host.convert(host.bounds, to: nil))
            #expect(more.frame.maxX < viewport.maxX)
            for element in SettingsBehaviorTestSupport.elements(in: host) where element.role == "AXButton" {
                #expect(element.frame.minX >= viewport.minX && element.frame.maxX <= more.frame.minX)
            }
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
