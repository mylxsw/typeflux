import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Typeflux

/// Hosts the attachment and command views in a real window and drives the
/// composer with key presses, so the palette flow is checked end to end.
@Suite("Ask command rendering", .serialized, .exclusiveUIState)
@MainActor
struct AskCommandRenderTests {
    @MainActor
    final class Host {
        let window: AskTestVoiceWindow
        let view: NSView

        init<V: View>(_ root: V, size: NSSize = NSSize(width: 900, height: 700)) {
            window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: root.environment(\.askGlassMaterialOverride, .opaque))
            hosting.frame = NSRect(origin: .zero, size: size)
            window.contentView = hosting
            view = hosting
            window.makeKeyAndOrderFront(nil)
        }

        /// Lays out and draws once so every visible body is evaluated.
        func draw() {
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap) }
        }

        func close() { window.orderOut(nil); window.close() }

        var editor: AskComposerTextView.Editor? {
            func find(_ view: NSView) -> AskComposerTextView.Editor? {
                if let editor = view as? AskComposerTextView.Editor { return editor }
                return view.subviews.lazy.compactMap(find).first
            }
            return find(view)
        }
    }

    private func settle(_ milliseconds: Int = 120) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }

    private func press(_ characters: String, keyCode: UInt16 = 0, in editor: NSTextView) async throws {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: editor.window?.windowNumber ?? 0, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        editor.keyDown(with: event)
        try await settle()
    }

    private func type(_ text: String, in editor: NSTextView) async throws {
        for character in text { try await press(String(character), in: editor) }
    }

    private func fixture() throws -> (AskTestFixture, Recorder) {
        let f = try AskTestFixture()
        let recorder = Recorder()
        f.model.commandSources = AskCommandSources(
            skills: { AskBuiltinSkills.all },
            mcpServers: { [AskMCPServerSummary(name: "github", enabled: true)] },
            remember: { recorder.notes.append($0) },
            privateByDefault: { false }
        )
        return (f, recorder)
    }

    final class Recorder { var notes: [String] = [] }

    @Test(arguments: [false, true]) func theWorkspacePaletteRunsCommandsFromTheKeyboard(compact: Bool) async throws {
        let (f, recorder) = try fixture()
        let photo = AskAttachment(kind: .image, name: "shot.png",
                                  image: AskAttachmentLoader.jpegDataURL(AskAttachmentFixture.image(width: 40, height: 30)))
        f.model.draft.append([photo, AskAttachment(kind: .file, name: "a.pdf", text: "x", truncated: true, pages: 2),
                              AskAttachment(kind: .folder, name: "src", path: "/tmp/src")])
        f.model.draft.skills = ["meeting-notes"]
        f.model.draft.mcpServers = ["github"]
        f.model.confirm("Done", for: .seconds(5))
        f.model.attachmentNotice = "Notice"
        let workspace = compact ? AnyView(VStack {
            Spacer(minLength: 0)
            AskComposer(model: f.model, compact: true, launcher: false)
        }) : AnyView(AskConversationView(model: f.model))
        let host = Host(workspace, size: compact ? NSSize(width: 360, height: 280) : NSSize(width: 1100, height: 760))
        defer { host.close(); f.model.resetSession() }
        try await settle(400)
        host.draw()
        let editor = try #require(host.editor)
        host.window.makeFirstResponder(editor)

        // "/" opens the palette; the arrows move; Escape closes it and keeps the text.
        try await press("/", in: editor)
        host.draw()
        try await press("", keyCode: 125, in: editor)
        try await press("", keyCode: 126, in: editor)
        try await press("\u{1b}", keyCode: 53, in: editor)
        #expect(f.model.draft.text == "/")
        try await type("x", in: editor)
        #expect(f.model.draft.text == "/x", "an escaped token stays closed while it is edited")
        f.model.draft.text = ""
        try await settle()

        // Tab opens a submenu; Return picks the highlighted model and clears the token.
        try await type("/model", in: editor)
        host.draw()
        try await press("\t", keyCode: 48, in: editor)
        #expect(f.model.draft.text == "/model ")
        host.draw()
        try await press("\r", keyCode: 36, in: editor)
        #expect(f.model.draft.text.isEmpty)
        #expect(f.model.commandFeedback != nil)

        // An argument command waits for its text, then runs with it.
        try await type("/remem", in: editor)
        try await press("\r", keyCode: 36, in: editor)
        #expect(f.model.draft.text == "/remember ")
        try await press("\r", keyCode: 36, in: editor)
        #expect(recorder.notes.isEmpty, "nothing to remember yet")
        try await type("Go", in: editor)
        host.draw()
        try await press("\r", keyCode: 36, in: editor)
        #expect(recorder.notes == ["Go"])
        #expect(f.model.draft.text.isEmpty)

        // Help lists everything again; a toggle runs at once.
        try await type("/help", in: editor)
        try await press("\r", keyCode: 36, in: editor)
        #expect(f.model.draft.text == "/")
        f.model.draft.text = ""
        try await settle()
        let memory = f.model.memorySwitchedOff(launcher: false)
        try await type("/memory", in: editor)
        try await press("\r", keyCode: 36, in: editor)
        #expect(f.model.memorySwitchedOff(launcher: false) != memory)

        // A skill toggles its chip off again.
        try await type("/meeting", in: editor)
        try await press("\r", keyCode: 36, in: editor)
        #expect(f.model.draft.skills == nil)

        // Text with no matching command stays text.
        try await type("/zzzz", in: editor)
        #expect(f.model.draft.text == "/zzzz")
        host.draw()
        f.model.draft.text = ""
        try await settle()

        // Tab on a plain command writes it out; search hands over to the window's palette.
        try await type("/sea", in: editor)
        try await press("\t", keyCode: 48, in: editor)
        #expect(f.model.draft.text == "/search")
        try await press("\r", keyCode: 36, in: editor)
        #expect(f.model.searchRequest == 1)
    }

    @Test func launcherSlashTextDoesNotGrowTheCard() async throws {
        let (f, _) = try fixture()
        var heights: [CGFloat] = []
        var dismissed = false
        // Search nothing on this Mac: once the shared index has scanned, "/me" matches real
        // applications (Messages, Menu Bar…) and their rows, not a palette, would grow the card.
        f.model.appIndex = AskTestAppIndex([])
        f.model.launcherDraft = AskDraft(includeScreenshot: false)
        f.model.launcherDraft.append([AskAttachment(kind: .file, name: "a.txt", text: "x")])
        let host = Host(VStack {
            AskLauncherView(model: f.model, onDismiss: { dismissed = true }, onHeightChange: { heights.append($0) })
            Spacer()
        }, size: NSSize(width: 720, height: 640))
        defer { host.close(); f.model.resetSession() }
        try await settle(400)
        let editor = try #require(host.editor)
        host.window.makeFirstResponder(editor)
        let closed = try #require(heights.last)
        #expect(closed > 0, "the native launcher has reported its height")
        host.draw()
        let width = editor.frame.width
        try await type("/me", in: editor)
        // The search the text starts must finish before the height is final.
        try await f.wait { !f.model.quickSearch.isSearching }
        host.draw()
        #expect((heights.last ?? 0) == closed, "ordinary slash text does not add a command palette")
        #expect(editor.frame.width == width, "nor does it narrow or widen the editor")
        #expect(f.model.launcherDraft.text == "/me")
        try await press("\u{1b}", keyCode: 53, in: editor)
        try await settle()
        #expect((heights.last ?? 0) == closed)
        #expect(dismissed, "Escape closes the launcher directly")
        #expect(f.model.launcherDraft.text == "/me")
    }

    @Test func standaloneViewsDrawEveryState() async throws {
        let (f, _) = try fixture()
        var state = AskCommandPaletteState()
        let rows = [
            AskCommand(action: .memory, name: "memory", title: "Memory", symbol: "brain", group: .context, kind: .toggle(on: true)),
            AskCommand(action: .localMode, name: "local", title: "Local", symbol: "desktopcomputer", group: .model, kind: .toggle(on: false)),
            AskCommand(action: .model, name: "model", title: "Model", symbol: "cpu", group: .model, kind: .submenu, trailing: "GPT"),
            AskCommand(action: .remember, name: "remember", title: "Remember", symbol: "pin", group: .context, kind: .argument, trailing: "text"),
            AskCommand(action: .skill("s"), name: "s", title: "", detail: "A skill", symbol: "bolt", group: .skills, kind: .token, badge: "Built-in", selected: true),
            AskCommand(action: .copyAnswer, name: "copy", title: "Copy", symbol: "doc.on.doc", group: .conversation, disabledReason: "No answer"),
            AskCommand(action: .newConversation, name: "new", title: "New", symbol: "square.and.pencil", group: .conversation, trailing: "⌘N"),
            AskCommand(action: .pickModel("m"), name: "Model A", title: "", symbol: "eye", group: .model, plain: true)
        ].map { AskCommandMatcher.Match(command: $0, score: 1, highlights: [0]) }
        state.update(rows: rows)
        var managed = 0
        var picked: [Int] = []
        var submenu = state
        submenu.parent = rows[2].command
        let host = Host(VStack(spacing: 12) {
            AskCommandPaletteView(state: state, onPick: { picked.append($0) }, onHighlight: { _ in }, onManage: { managed += 1 })
            AskCommandPaletteView(state: submenu, onPick: { _ in }, onHighlight: { _ in }, onManage: nil)
            AskAttachChoices(clipboardHasImage: false) { _ in }
            HStack {
                AskAttachButton(model: f.model, launcher: false)
                AskSlashShortcut(action: {})
                AskSlashShortcut(disabled: true, action: {})
            }
            AskAttachmentStripView(items: [], onPreview: {}, onRemove: { _ in },
                                   attachments: [AskAttachment(kind: .folder, name: "src", path: "/tmp/src")], loading: true,
                                   choices: [AskChosenTool(kind: .skill, name: "s"), AskChosenTool(kind: .mcpServer, name: "github")])
            HStack {
                AskSentFileChip(attachment: AskAttachment(kind: .file, name: "a.md", text: "body", pages: 1))
                AskSentFileChip(attachment: AskAttachment(kind: .folder, name: "src", path: "/tmp/src"))
            }
        }, size: NSSize(width: 760, height: 1400))
        defer { host.close() }
        try await settle(300)
        host.draw()
        #expect(AskChosenTool(kind: .mcpServer, name: "github").caption == L("ask.command.chip.mcp"))
        #expect(AskChosenTool(kind: .skill, name: "s").symbol == "bolt")
    }

    @Test func droppedProvidersBecomeSources() async throws {
        let dir = try AskAttachmentFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "a".write(to: file, atomically: true, encoding: .utf8)
        let png = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 4, height: 4), type: .png)
        let image = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        image.suggestedName = "drop.png"
        let fileProvider = NSItemProvider(item: file as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let sources = await AskAttachmentSource.load(from: [fileProvider, image, NSItemProvider()])
        #expect(sources.count == 2)
        #expect(sources.first == .file(file))
        if case let .image(data, name) = sources.last { #expect(name == "drop.png"); #expect(!data.isEmpty) } else { Issue.record("expected image") }
    }
}
