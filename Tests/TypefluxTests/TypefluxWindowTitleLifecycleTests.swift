import AppKit
import Testing
@testable import TypefluxUI

@Suite("Window title lifecycle", .exclusiveUIState)
@MainActor
struct TypefluxWindowTitleLifecycleTests {
    @Test func metadataSurvivesToolbarUpdatesAndStopsAfterDetachment() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TypefluxWindowTitleBridge.TitleView()
        view.title = "Settings"
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        #expect(window.title == "Settings")
        #expect(window.titleVisibility == .hidden)
        window.title = ""
        try await SettingsBehaviorTestSupport.wait { window.title == "Settings" }
        window.titleVisibility = .visible
        window.toolbar = NSToolbar(identifier: "TitleLifecycle")
        try await SettingsBehaviorTestSupport.wait { window.titleVisibility == .hidden }
        view.title = "Account"
        view.synchronize()
        #expect(window.title == "Account")
        window.contentView = nil
        window.title = "Detached"
        window.titleVisibility = .visible
        try await Task.sleep(for: .milliseconds(80))
        #expect(window.titleVisibility == .visible)
        #expect(window.title == "Detached", "title observation ends with the hosted view")
        #expect(window.contentView == nil)
    }
}
