import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Opt-in renders of the attachment strip and the slash command palette with
/// the production composer (set TYPEFLUX_ASK_SNAPSHOTS). Keys are sent to the
/// real editor, so the palette opens the way it does for a user.
@Suite("Ask command snapshots", .serialized)
@MainActor
struct AskCommandVisualTests {
    private func editor(in view: NSView) -> AskComposerTextView.Editor? {
        if let editor = view as? AskComposerTextView.Editor { return editor }
        return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }

    private func type(_ characters: String, keyCode: UInt16 = 0, into editor: NSTextView) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: editor.window?.windowNumber ?? 0, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        editor.keyDown(with: event)
    }

    private func snapshot(_ hosting: NSView, to url: URL) throws {
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
        #expect(png.count > 10000)
    }

    @Test func renderAttachmentsAndCommandPalette() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let fixture = try AskTestFixture()
            fixture.model.commandSources = AskCommandSources(
                skills: { AskBuiltinSkills.all },
                mcpServers: { [AskMCPServerSummary(name: "github", enabled: true), AskMCPServerSummary(name: "notion", enabled: false)] }
            )
            let now = Date()
            let photo = try AskAttachmentLoader.image(
                data: AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 320, height: 200), type: .png),
                name: "设计稿-v2.png", byteSize: 82000)
            let conversation = AskConversation(id: "files", title: "对照需求看设计稿", revision: 1, updatedAt: now, messages: [
                .init(id: "q1", role: "user", text: "对照这张图和需求文档，看看设计稿还缺什么", createdAt: now,
                      attachments: [photo, AskAttachment(kind: .file, name: "产品需求说明书.pdf", text: "需求", pages: 14),
                                    AskAttachment(kind: .folder, name: "typeflux", path: "/Users/me/typeflux")],
                      skills: [AskSkillUse(name: "meeting-notes", instructions: "x")]),
                .init(id: "a1", role: "assistant", text: "设计稿覆盖了附件上传和命令面板，还缺少：\n\n- 附件错误状态\n- 命令为空时的提示", createdAt: now)
            ], run: .init(id: "run", deviceId: "device", status: "completed", steps: 1, updatedAt: now, tools: [], pending: []))
            await fixture.api.seed(conversation)
            await fixture.model.refreshHistory()
            await fixture.model.select(conversation.id)
            fixture.model.draft.append([photo, AskAttachment(kind: .file, name: "usage-2026-09.csv", text: "a,b", truncated: true),
                                        AskAttachment(kind: .folder, name: "typeflux", path: "/Users/me/typeflux")])
            fixture.model.draft.skills = ["meeting-notes"]
            fixture.model.draft.mcpServers = ["github"]

            let size = NSSize(width: 1100, height: 760)
            let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            let hosting = NSHostingView(rootView: AskConversationView(model: fixture.model).environment(\.askGlassMaterialOverride, .opaque))
            hosting.frame = NSRect(origin: .zero, size: size)
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.close(); fixture.model.resetSession() }
            try await Task.sleep(for: .milliseconds(500))
            try snapshot(hosting, to: root.appendingPathComponent("attachments-strip-\(name).png"))

            let field = try #require(editor(in: hosting))
            window.makeFirstResponder(field)
            type("/", into: field)
            try await Task.sleep(for: .milliseconds(400))
            try snapshot(hosting, to: root.appendingPathComponent("commands-palette-\(name).png"))

            for character in "mo" { type(String(character), into: field) }
            try await Task.sleep(for: .milliseconds(300))
            try snapshot(hosting, to: root.appendingPathComponent("commands-filtered-\(name).png"))

            type("\t", keyCode: 48, into: field)
            try await Task.sleep(for: .milliseconds(300))
            #expect(fixture.model.draft.text == "/model ")
            try snapshot(hosting, to: root.appendingPathComponent("commands-model-submenu-\(name).png"))

            type("\u{1b}", keyCode: 53, into: field)
            try await Task.sleep(for: .milliseconds(200))
            #expect(fixture.model.draft.text == "/model ", "escape closes the palette and keeps the text")
        }
    }
}
