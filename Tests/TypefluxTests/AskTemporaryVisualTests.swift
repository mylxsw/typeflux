import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Production temporary-conversation surfaces rendered with synthetic data. Set
/// `TYPEFLUX_TEMPORARY_SNAPSHOTS` to a directory to write them; otherwise it does nothing.
@Suite("Ask temporary conversation snapshots", .serialized, .exclusiveUIState)
@MainActor
struct AskTemporaryVisualTests {
    @Test func renderTemporaryConversationSurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_TEMPORARY_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        await fixture.api.seed(.init(id: "a", title: "讲讲这一屏在做什么", revision: 1, updatedAt: Date(), messages: []))
        await fixture.api.seed(.init(id: "b", title: "早上好呀。", revision: 1,
                                     updatedAt: Date().addingTimeInterval(-86400), messages: []))
        await fixture.model.refreshHistory()

        fixture.model.newConversation(temporary: true)
        for dark in [false, true] {
            try await render(AskConversationView(model: fixture.model), size: NSSize(width: 1100, height: 720),
                             dark: dark, file: root.appendingPathComponent("workspace-new-\(dark ? "dark" : "light").png"))
        }
        fixture.model.draft.text = "这个药和酒一起吃有问题吗"
        fixture.model.submitDraft()
        try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.selected?.run?.status == "completed" }
        for dark in [false, true] {
            try await render(AskConversationView(model: fixture.model), size: NSSize(width: 1100, height: 720),
                             dark: dark, file: root.appendingPathComponent("workspace-chat-\(dark ? "dark" : "light").png"))
        }
        try await render(VStack(alignment: .leading, spacing: 16) {
            AskNewConversationMenu(model: fixture.model) {}
            AskLocalModeCard(status: .make(model: fixture.model, signedIn: true), onOpenSearchSettings: {}, onSignIn: {})
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(AskTheme.surface),
                         size: NSSize(width: 380, height: 560), dark: true,
                         file: root.appendingPathComponent("menu-and-card-dark.png"))

        fixture.model.endTemporaryConversation()
        fixture.model.toggleTemporary(launcher: true)
        fixture.model.launcherDraft.text = "帮我把选中的条款翻成英文"
        for dark in [false, true] {
            try await render(AskLauncherView(model: fixture.model, onDismiss: {}), size: NSSize(width: 700, height: 220),
                             dark: dark, file: root.appendingPathComponent("launcher-\(dark ? "dark" : "light").png"))
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, dark: Bool, file: URL) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view.environment(\.askGlassMaterialOverride, .opaque)
            .frame(width: size.width, height: size.height, alignment: .top))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(500))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: file)
        #expect(png.count > 2000)
    }
}
