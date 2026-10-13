import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@MainActor
@Suite(.exclusiveUIState)
struct ClipboardPreviewMotionTests {
    @Test(arguments: InterfaceStyle.allCases)
    func openingAndClosingHaveIntermediateFramesAndKeepTheWindowCentred(_ style: InterfaceStyle) async throws {
        let closedWidth = ClipboardPanelView.width(for: style)
        let openWidth = ClipboardPanelView.size(showsPreview: true, style: style).width
        try await withPanel(style: style) { controller, model, panel, host in
            let center = panel.frame.midX
            let top = panel.frame.maxY
            #expect(host.sizingOptions.isEmpty, "SwiftUI cannot independently resize the window")
            try snapshot(host, name: "closed", style: style)
            for shows in [true, false] {
                let start = panel.frame.width
                model.showsPreview = shows
                #expect(controller.isResizingPreview)
                #expect(panel.frame.width == start, "A toggle starts at the current on-screen width")
                var intermediate = 0
                var captured = false
                for _ in 0 ..< 150 where controller.isResizingPreview {
                    try await Task.sleep(for: .milliseconds(10))
                    checkSynchronized(controller: controller, panel: panel, host: host, center: center, top: top)
                    if panel.frame.width > closedWidth && panel.frame.width < openWidth { intermediate += 1 }
                    if !captured, (closedWidth + 100 ... closedWidth + 200).contains(panel.frame.width) {
                        try snapshot(host, name: shows ? "opening" : "closing", style: style)
                        captured = true
                    }
                }
                #expect(intermediate >= 2)
                #expect(!controller.isResizingPreview)
                #expect(panel.frame.width == ClipboardPanelView.size(showsPreview: shows, style: style).width)
                try snapshot(host, name: shows ? "open" : "closed-again", style: style)
            }
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func rapidReversalsKeepTheCurrentFrameAndLandOnTheLastRequestedState(_ style: InterfaceStyle) async throws {
        let closedWidth = ClipboardPanelView.width(for: style)
        let openWidth = ClipboardPanelView.size(showsPreview: true, style: style).width
        try await withPanel(style: style) { controller, model, panel, host in
            let center = panel.frame.midX
            let top = panel.frame.maxY
            model.togglePreview()
            try await Task.sleep(for: .milliseconds(80))
            let middle = panel.frame
            #expect(middle.width > closedWidth && middle.width < openWidth)
            model.togglePreview()
            #expect(panel.frame == middle, "Reversing cannot snap to either endpoint")
            try await Task.sleep(for: .milliseconds(40))
            let reversing = panel.frame
            model.togglePreview()
            #expect(panel.frame == reversing)
            for _ in 0 ..< 150 where controller.isResizingPreview {
                try await Task.sleep(for: .milliseconds(10))
                checkSynchronized(controller: controller, panel: panel, host: host, center: center, top: top)
            }
            #expect(!controller.isResizingPreview)
            #expect(panel.frame.width == openWidth)
            #expect(model.showsPreview)
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func reducedMotionAppliesTheCentredSizeImmediately(_ style: InterfaceStyle) async throws {
        try await withPanel(style: style) { controller, model, panel, host in
            controller.reduceMotion = { true }
            let center = panel.frame.midX
            let top = panel.frame.maxY
            model.togglePreview()
            #expect(panel.frame.width == ClipboardPanelView.size(showsPreview: true, style: style).width)
            #expect(!controller.isResizingPreview)
            checkSynchronized(controller: controller, panel: panel, host: host, center: center, top: top)
            model.togglePreview()
            #expect(panel.frame.width == ClipboardPanelView.width(for: style))
            checkSynchronized(controller: controller, panel: panel, host: host, center: center, top: top)
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func dismissalCancelsTheMotionAndReopeningUsesTheRequestedSize(_ style: InterfaceStyle) async throws {
        try await withPanel(style: style) { controller, model, panel, host in
            model.togglePreview()
            try await Task.sleep(for: .milliseconds(40))
            controller.dismiss()
            let stopped = panel.frame
            #expect(!controller.isResizingPreview)
            try await Task.sleep(for: .milliseconds(60))
            #expect(panel.frame == stopped)
            controller.present(model)
            #expect(controller.presentedWindow === panel)
            #expect(panel.frame.width == ClipboardPanelView.size(showsPreview: true, style: style).width)
            #expect(!controller.isResizingPreview)
            checkSynchronized(controller: controller, panel: panel, host: host, center: try #require(panel.screen).visibleFrame.midX,
                              top: panel.frame.maxY)
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func standaloneLayoutUsesFinalSizeAndControlledLayoutBoundsTheWidth(_ style: InterfaceStyle) {
        let layout = ClipboardPanelLayout()
        let closedWidth = ClipboardPanelView.width(for: style)
        let openWidth = ClipboardPanelView.size(showsPreview: true, style: style).width
        #expect(layout.width == nil)
        layout.setWidth(100, style: style)
        #expect(layout.width == closedWidth)
        layout.setWidth(closedWidth + 100, style: style)
        #expect(layout.width == closedWidth + 100)
        layout.setWidth(closedWidth + 100, style: style)
        #expect(layout.width == closedWidth + 100)
        layout.setWidth(1200, style: style)
        #expect(layout.width == openWidth)
    }

    private func checkSynchronized(controller: ClipboardPanelController, panel: NSWindow, host: NSHostingView<AnyView>,
                                   center: CGFloat, top: CGFloat) {
        #expect(abs(panel.frame.midX - center) <= 0.5)
        #expect(abs(panel.frame.maxY - top) <= 0.5)
        #expect(host.frame.size == panel.frame.size)
        #expect(controller.contentViewportWidth == panel.frame.width)
    }

    private func snapshot(_ host: NSHostingView<AnyView>, name: String, style: InterfaceStyle) throws {
        guard let output = ProcessInfo.processInfo.environment["TYPEFLUX_CLIPBOARD_SNAPSHOT_DIR"] else { return }
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let canvas = NSImage(size: ClipboardPanelView.size(showsPreview: true, style: style))
        canvas.lockFocus()
        NSColor(white: 0.08, alpha: 1).setFill()
        NSRect(origin: .zero, size: canvas.size).fill()
        rep.draw(in: NSRect(x: (canvas.size.width - host.bounds.width) / 2, y: 0,
                            width: host.bounds.width, height: host.bounds.height))
        canvas.unlockFocus()
        let tiff = try #require(canvas.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("clipboard-motion-\(name)-\(style.rawValue).png"))
    }

    private func withPanel(
        style: InterfaceStyle,
        _ body: (ClipboardPanelController, ClipboardPanelModel, NSWindow, NSHostingView<AnyView>) async throws -> Void
    ) async throws {
        let suite = "ClipboardPreviewMotionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.appearanceMode = .dark
        settings.interfaceStyle = style
        let controller = ClipboardPanelController(settingsStore: settings)
        controller.reduceMotion = { false }
        let model = ClipboardPanelModel()
        model.reset(entries: [ClipboardTestSupport.entry(.text, text: "A preview that stays visible while closing.")])
        controller.present(model)
        defer { controller.dismiss() }
        let panel = try #require(controller.presentedWindow)
        let host = try #require(panel.contentView as? NSHostingView<AnyView>)
        #expect(abs(panel.frame.midX - (panel.screen?.visibleFrame.midX ?? panel.frame.midX)) < 1)
        try await body(controller, model, panel, host)
    }
}
