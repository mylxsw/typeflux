import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Draws `sys` in the real launcher, dark and light. With `TYPEFLUX_SYSINFO_SNAPSHOTS=<dir>`
/// the PNGs are written there for review.
@Suite("System info visuals", .serialized, .exclusiveUIState)
@MainActor
struct SystemInfoVisualTests {
    static let directory = ProcessInfo.processInfo.environment["TYPEFLUX_SYSINFO_SNAPSHOTS"]

    private func snapshot(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        guard let directory = Self.directory else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }

    private func launcher(_ name: String, light: Bool = false, facts: SystemInfoFacts = SystemInfoFixtures.laptop(),
                          filter: String = "", prepare: (AskConversationModel) -> Void = { _ in }) async throws {
        let previousStore = KeychainTokenStore.useInMemoryStoreForTesting
        KeychainTokenStore.useInMemoryStoreForTesting = true
        _ = AuthState.shared
        KeychainTokenStore.useInMemoryStoreForTesting = previousStore
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let model = fixture.model
        let store = SystemInfoStore(reader: FakeSystemInfoReader(facts), now: { SystemInfoFixtures.now })
        store.refresh()
        await store.settle()
        model.systemInfoStore = store
        model.launcherDraft.text = "sys"
        #expect(model.enterLauncherKeywordFromText(pluginID: AskSystemInfoPlugin.id))
        model.launcherDraft.text = filter
        prepare(model)
        let size = NSSize(width: AskMetrics.launcherWidth, height: 660)
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                        backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let hosting = NSHostingView(rootView: AskLauncherView(model: model, onDismiss: {}, onHeightChange: { _ in })
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(AskTheme.surface))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(400))
        try snapshot(hosting, name: name)
        #expect(model.showsSystemInfo)
    }

    @Test func `launcher states`() async throws {
        try await withSystemMonitorLanguageAsync {
            try await launcher("sys-overview")
            try await launcher("sys-overview-light", light: true)
            try await launcher("sys-storage") { $0.systemInfo.show(.storage) }
            try await launcher("sys-network") { model in
                model.systemInfo.show(.network)
                model.systemInfo.select("network.en0.mac")
            }
            try await launcher("sys-system-revealed") { model in
                model.systemInfo.show(.system)
                model.systemInfo.select("system.serial")
                model.systemInfo.toggleReveal("system.serial")
            }
            try await launcher("sys-search-ip", filter: "ip")
            try await launcher("sys-search-none", filter: "nothing-like-this")
            try await launcher("sys-desktop", facts: SystemInfoFixtures.desktop())
        }
        try await withSystemMonitorLanguageAsync(.simplifiedChinese) {
            try await launcher("sys-overview-zh")
            try await launcher("sys-display-zh-light", light: true) { $0.systemInfo.show(.display) }
        }
    }
}
