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
                          filter: String = "",
                          inspect: (NSWindow, AskConversationModel) async throws -> Void = { _, _ in },
                          prepare: (AskConversationModel) -> Void = { _ in }) async throws {
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
        try await inspect(window, model)
    }

    @Test(arguments: AppLanguage.allCases, [false, true])
    func `summary icon stays compact accessible and copies`(language: AppLanguage, light: Bool) async throws {
        _ = NSApplication.shared
        // SwiftUI only exposes its accessibility tree when an assistive client requests it.
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("system.info.summary.\(UUID().uuidString)"))
        let previous = AskQuickResults.pasteboard
        AskQuickResults.pasteboard = pasteboard
        defer {
            NSApp.accessibilitySetValue(previousAccessibility ?? false, forAttribute: attribute)
            AskQuickResults.pasteboard = previous
            pasteboard.releaseGlobally()
        }
        try await withSystemMonitorLanguageAsync(language) {
            try await launcher("sys-summary-\(language.rawValue)-\(light ? "light" : "dark")", light: light,
                               inspect: { window, model in
                                   let button = try SettingsBehaviorTestSupport.button(
                                       L("system.info.copySummary"),
                                       in: window
                                   )
                                   #expect(button
                                       .value("accessibilityIdentifier") as? String == "system.info.copySummary")
                                   #expect(
                                       button.frame.width >= 28 && button.frame.width <= 32,
                                       "the icon leaves room for the model name"
                                   )
                                   #expect(button.frame.height >= 28, "the copy target is comfortably clickable")
                                   try button.press()
                                   for _ in 0 ..< 100 where pasteboard.string(forType: .string) == nil {
                                       try await Task.sleep(for: .milliseconds(10))
                                   }
                                   let snapshot = try #require(model.systemInfoStore.snapshot)
                                   #expect(pasteboard.string(forType: .string) == SystemInfoReport.summary(snapshot))
                                   #expect(model.showsSystemInfo, "copying keeps the configuration open")
                               })
        }
    }

    @Test func `launcher states`() async throws {
        try await withSystemMonitorLanguageAsync {
            try await launcher("sys-overview")
            try await launcher("sys-overview-light", light: true)
            try await launcher("sys-storage", prepare: { $0.systemInfo.show(.storage) })
            try await launcher("sys-system", prepare: { $0.systemInfo.show(.system) })
            try await launcher("sys-system-light", light: true, prepare: { $0.systemInfo.show(.system) })
            try await launcher("sys-network", prepare: { model in
                model.systemInfo.show(.network)
                model.systemInfo.select("network.en0.mac")
            })
            try await launcher("sys-system-revealed", prepare: { model in
                model.systemInfo.show(.system)
                model.systemInfo.select("system.serial")
                model.systemInfo.toggleReveal("system.serial")
            })
            try await launcher("sys-search-ip", filter: "ip")
            try await launcher("sys-search-none", filter: "nothing-like-this")
            try await launcher("sys-desktop", facts: SystemInfoFixtures.desktop())
        }
        try await withSystemMonitorLanguageAsync(.simplifiedChinese) {
            try await launcher("sys-overview-zh")
            try await launcher("sys-display-zh-light", light: true, prepare: { $0.systemInfo.show(.display) })
        }
    }
}
