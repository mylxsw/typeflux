import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// GUL-464 surfaces rendered with synthetic data: the new page with its storage bar,
/// large content previews, skill tokens and the sidebar's filters. Set
/// `TYPEFLUX_CHAT_HOME_SNAPSHOTS` to a directory to write them; otherwise it does nothing.
@Suite("Ask chat home snapshots", .serialized, .exclusiveUIState)
@MainActor
struct AskChatHomeVisualTests {
    @Test func renderChatHomeSurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_CHAT_HOME_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        fixture.model.commandSources.skills = {
            [AskSkill(name: "translate-polish", description: "翻译或润色文本，保留原意、术语和格式", body: ""),
             AskSkill(name: "meeting-notes", description: "整理成包含决定和待办事项的纪要", body: "")]
        }
        let tasks = ["优化临时对话与工作区选择", "修复工作区与侧边栏显示", "排查文件搜索结果空白", "分析功能模块互相阻塞问题",
                     "帮我实现一个贪吃蛇的网页游戏", "帮我实现一个俄罗斯方块小游戏", "彻底卸载 Unsloth 应用并清理"]
        for (index, title) in tasks.enumerated() {
            var work = AskConversation(id: "w\(index)", title: title, revision: 1,
                                       updatedAt: Date().addingTimeInterval(-Double(index) * 3600), messages: [])
            work.kind = "work"
            await fixture.api.seed(work)
        }
        for (index, title) in ["薄肌是什么意思", "提取截图中的文字", "婴儿车什么时候开始用", "服务器上的 go-build 目录存储空间"]
            .enumerated() {
            var chat = AskConversation(id: "c\(index)", title: title, revision: 1,
                                       updatedAt: Date().addingTimeInterval(-Double(index) * 5400 - 600), messages: [])
            chat.kind = "chat"
            await fixture.api.seed(chat)
        }
        await fixture.model.refreshHistory()
        let size = NSSize(width: 1280, height: 820)

        fixture.model.newConversation()
        fixture.model.setConversationKind(.chat, launcher: false)
        fixture.model.draft.memory = AskMemory(global: "回答简洁")
        fixture.model.draft.text = "对比这些材料，整理成一份竞品调研"
        fixture.model.draft.attachments = Self.attachments
        fixture.model.draft.skills = ["translate-polish"]
        for dark in [true, false] {
            try await render(AskConversationView(model: fixture.model), size: size, dark: dark,
                             file: root.appendingPathComponent("new-chat-\(dark ? "dark" : "light").png"))
        }

        fixture.model.newConversation()
        fixture.model.setConversationKind(.work, launcher: false)
        fixture.model.draft.attachments = [AskAttachment(kind: .folder, name: "typeflux", path: "/Users/me/typeflux")]
        try await render(AskConversationView(model: fixture.model), size: size, dark: true,
                         file: root.appendingPathComponent("new-work-dark.png"))

        fixture.model.newConversation()
        fixture.model.setConversationKind(.chat, launcher: false)
        fixture.model.toggleTemporary(launcher: false)
        try await render(AskConversationView(model: fixture.model), size: size, dark: true,
                         file: root.appendingPathComponent("new-temporary-dark.png"))
        fixture.model.toggleTemporary(launcher: false)

        for signedIn in [false, true] {
            for dark in [false, true] {
                try await render(AskStorageChoiceMenu(selection: .temporary, signedIn: signedIn) { _ in },
                                 size: NSSize(width: 300, height: signedIn ? 230 : 156), dark: dark,
                                 file: root.appendingPathComponent("storage-\(signedIn ? "signed-in" : "signed-out")-\(dark ? "dark" : "light").png"))
            }
        }

        fixture.model.draft.text = "对比这些材料，整理成一份竞品调研"
        fixture.model.draft.attachments = Self.attachments
        fixture.model.draft.skills = ["translate-polish"]
        fixture.model.submitDraft()
        try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.selected?.run?.status == "completed" }
        for dark in [true, false] {
            try await render(AskConversationView(model: fixture.model), size: size, dark: dark,
                             file: root.appendingPathComponent("conversation-\(dark ? "dark" : "light").png"))
        }
    }

    private static var attachments: [AskAttachment] {
        [AskAttachment(kind: .image, name: "HapiGo_2026-10-21_12.51.38.png", byteSize: 1_200_000,
                       image: imageDataURL(colors: [.systemIndigo, .systemPink])),
         AskAttachment(kind: .file, name: "Typeflux 产品规划 v3.pdf", byteSize: 820_000,
                       text: "Typeflux 产品规划 v3\n一、目标用户与场景\n语音输入、改写和翻译贯穿整个工作流。二、竞品对比……",
                       pages: 12),
         AskAttachment(kind: .file, name: "the-age-of-experience.md", byteSize: 8_000,
                       text: "# The Age of Experience\nAgents learn from their own experience rather than human data.")]
    }

    /// A small gradient, enough for a tile to show a real picture.
    private static func imageDataURL(colors: [NSColor]) -> String {
        let image = NSImage(size: NSSize(width: 240, height: 240), flipped: false) { rect in
            NSGradient(colors: colors)?.draw(in: rect, angle: 45)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 40, dy: 70), xRadius: 14, yRadius: 14).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return "" }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
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
        try await Task.sleep(for: .milliseconds(800))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: file)
        #expect(png.count > 2000)
    }
}
