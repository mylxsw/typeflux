import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Production Chat and Work surfaces rendered with synthetic data. Set
/// `TYPEFLUX_KIND_SNAPSHOTS` to a directory to write them; otherwise it does nothing.
@Suite("Ask conversation kind snapshots", .serialized, .exclusiveUIState)
@MainActor
struct AskConversationKindVisualTests {
    @Test func renderChatAndWorkSurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_KIND_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var work = AskConversation(id: "w", title: "整理下载文件夹里的发票", revision: 1, updatedAt: Date(), messages: [])
        work.kind = "work"
        var chat = AskConversation(id: "c", title: "这个药和酒一起吃有问题吗", revision: 1,
                                   updatedAt: Date().addingTimeInterval(-600), messages: [])
        chat.kind = "chat"
        await fixture.api.seed(work)
        await fixture.api.seed(chat)
        await fixture.model.refreshHistory()

        for kind in AskConversationKind.allCases {
            fixture.model.newConversation()
            fixture.model.setConversationKind(kind, launcher: false)
            for dark in [false, true] {
                try await render(AskConversationView(model: fixture.model), size: NSSize(width: 1100, height: 720),
                                 dark: dark, file: root.appendingPathComponent("new-\(kind.rawValue)-\(dark ? "dark" : "light").png"))
                try await render(AskConversationView(model: fixture.model), size: NSSize(width: 440, height: 720),
                                 dark: dark, file: root.appendingPathComponent("new-\(kind.rawValue)-compact-\(dark ? "dark" : "light").png"))
            }
        }
        for kind in AskConversationKind.allCases {
            fixture.model.setConversationKind(kind, launcher: true)
            fixture.model.launcherDraft.text = "整理这个文件夹里的发票"
            try await render(AskLauncherView(model: fixture.model, onDismiss: {}), size: NSSize(width: 760, height: 240),
                             dark: true, file: root.appendingPathComponent("launcher-\(kind.rawValue)-dark.png"))
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
