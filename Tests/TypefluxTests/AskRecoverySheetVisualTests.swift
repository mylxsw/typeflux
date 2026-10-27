import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct AskRecoverySheetVisualTests {
    @Test func `recovery uses one in-window panel without native sheet bands`() async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let value = AskRecoveryFixture.conversation()
        let audit = AskRecoveryFixture.audit(value)
        #expect(try await fixture.cache.claimExecution(audit, owner: "owner"))
        try await fixture.cache.saveReceipt(
            AskRecoveryFixture.timedOutReceipt(value),
            identity: audit.identity,
            owner: "owner"
        )
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

        try await Task.sleep(for: .milliseconds(150))
        #expect(window.attachedSheet == nil)
        hosting.layoutSubtreeIfNeeded()
        let image = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        if let path = ProcessInfo.processInfo.environment["TYPEFLUX_RECOVERY_SHEET_IMAGE"],
           let data = image.representation(using: .png, properties: [:]) {
            try data.write(to: URL(fileURLWithPath: path))
        }
        let x = image.pixelsWide / 2 + 460
        let top = try #require(image.colorAt(x: x, y: image.pixelsHigh / 2 - 105)?.usingColorSpace(.deviceRGB))
        let bottom = try #require(image.colorAt(x: x, y: image.pixelsHigh / 2 + 105)?.usingColorSpace(.deviceRGB))
        #expect(abs(top.redComponent - bottom.redComponent) < 0.04)
        #expect(abs(top.greenComponent - bottom.greenComponent) < 0.04)
        #expect(abs(top.blueComponent - bottom.blueComponent) < 0.04)
    }
}
