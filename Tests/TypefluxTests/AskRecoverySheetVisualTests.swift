import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask recovery sheet surface", .exclusiveUIState)
@MainActor
struct AskRecoverySheetVisualTests {
    @Test func `native sheet has no top or bottom background bands`() async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let value = AskRecoveryFixture.conversation()
        let audit = AskRecoveryFixture.audit(value)
        #expect(try await fixture.cache.claimExecution(audit, owner: "owner"))
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        fixture.model.inspectingRecovery = true

        let size = NSSize(width: 1100, height: 740)
        let hosting = NSHostingView(rootView: AskConversationView(model: fixture.model)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        hosting.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.appearance = hosting.appearance
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        var sheet: NSWindow?
        for _ in 0 ..< 50 {
            sheet = window.attachedSheet
            if sheet != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let content = try #require(sheet?.contentView)
        content.layoutSubtreeIfNeeded()
        let image = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: image)
        if let path = ProcessInfo.processInfo.environment["TYPEFLUX_RECOVERY_SHEET_IMAGE"],
           let data = image.representation(using: .png, properties: [:]) {
            try data.write(to: URL(fileURLWithPath: path))
        }
        let x = 130
        let top = try #require(image.colorAt(x: x, y: 12))
        let topInside = try #require(image.colorAt(x: x, y: 65))
        let bottom = try #require(image.colorAt(x: x, y: image.pixelsHigh - 13))
        let bottomInside = try #require(image.colorAt(x: x, y: image.pixelsHigh - 66))
        for (edge, inside) in [(top, topInside), (bottom, bottomInside)] {
            let edge = try #require(edge.usingColorSpace(.deviceRGB))
            let inside = try #require(inside.usingColorSpace(.deviceRGB))
            #expect(abs(edge.redComponent - inside.redComponent) < 0.04)
            #expect(abs(edge.greenComponent - inside.greenComponent) < 0.04)
            #expect(abs(edge.blueComponent - inside.blueComponent) < 0.04)
        }
    }
}
