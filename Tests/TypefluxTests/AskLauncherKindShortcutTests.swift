import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Launcher mode shortcuts", .serialized, .exclusiveUIState)
@MainActor
struct AskLauncherKindShortcutTests {
    @Test func modeKeysRequireCommandAloneAndLeaveSelectedTextForCopying() throws {
        #expect(AskLauncherKindShortcuts.key(for: .chat) == "C")
        #expect(AskLauncherKindShortcuts.key(for: .work) == "W")
        for (code, character, kind) in [(UInt16(8), "c", AskConversationKind.chat), (13, "w", .work)] {
            for text in [character, character.uppercased(), ""] {
                #expect(AskLauncherKindShortcuts.kind(for: try event(code, text)) == kind)
            }
            for flags: NSEvent.ModifierFlags in [[], .shift, [.command, .shift], [.command, .option], [.command, .control]] {
                #expect(AskLauncherKindShortcuts.kind(for: try event(code, character, flags)) == nil)
            }
        }
        #expect(AskLauncherKindShortcuts.kind(for: try event(8, "c"), hasSelection: true) == nil)
        #expect(AskLauncherKindShortcuts.kind(for: try event(8, ""), hasSelection: true) == nil)
        #expect(AskLauncherKindShortcuts.kind(for: try event(13, "w"), hasSelection: true) == .work)
        #expect(AskLauncherKindShortcuts.kind(for: try event(8, "x")) == nil)
        #expect(AskLauncherKindShortcuts.kind(for: try event(0, "")) == nil)
    }

    @Test func nativeKeyEquivalentsAndKeyDownSwitchOnlyTheLauncher() throws {
        let window = AskTestVoiceWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                                        styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = AskComposerTextView.Editor()
        window.contentView = editor
        window.makeFirstResponder(editor)
        var modes: [AskConversationKind] = []
        editor.onKindShortcut = { modes.append($0) }
        #expect(editor.performKeyEquivalent(with: try event(13, "w")))
        editor.keyDown(with: try event(8, "c"))
        #expect(modes == [.work, .chat])
        // Results that offer copying retain Command-C without changing the mode.
        editor.onCommandKey = { $0 == .commandC }
        #expect(editor.performKeyEquivalent(with: try event(8, "c")))
        #expect(modes == [.work, .chat])
        editor.onCommandKey = nil
        editor.contextID = "chat:new"
        #expect(!editor.performKeyEquivalent(with: try event(13, "w")))
        #expect(modes == [.work, .chat])
        editor.contextID = "launcher"
        editor.setMarkedText("draft", selectedRange: NSRange(location: 0, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!editor.performKeyEquivalent(with: try event(13, "w")))
        #expect(modes == [.work, .chat])
    }

    @Test(arguments: ["", "An unsent question"])
    func launcherRoutesModeKeysWithoutClosingOrSubmittingItsDraft(text: String) async throws {
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: text)
        defer { launcher.close() }
        launcher.fixture.model.setConversationKind(.chat, launcher: true)
        launcher.window.makeFirstResponder(launcher.editor)
        #expect(launcher.editor.performKeyEquivalent(with: try event(13, "w")))
        #expect(launcher.fixture.model.conversationKind(launcher: true) == .work)
        try await launcher.press(8, .command)
        #expect(launcher.fixture.model.conversationKind(launcher: true) == .chat)
        #expect(launcher.fixture.model.launcherDraft.text == text)
        #expect(launcher.dismissed == 0)
        #expect(await launcher.fixture.api.sends.isEmpty)
    }

    @Test func compactModeHintsAppearWithoutResizingTheSwitch() async throws {
        let directory = ProcessInfo.processInfo.environment["TYPEFLUX_KIND_SHORTCUT_SNAPSHOTS"]
        if let directory { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var renders: [Data] = []
            var sizes: [NSSize] = []
            for visible in [false, true] {
                let hosting = NSHostingView(rootView:
                    AskConversationKindSwitch(selection: .chat, compact: true, onSelect: { _ in })
                        .padding(16)
                        .environment(\.askLauncherNumberHints, visible)
                        .background(AskTheme.composerSurface)
                )
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 64),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = hosting
                window.orderFront(nil)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(80))
                hosting.layoutSubtreeIfNeeded()
                sizes.append(hosting.fittingSize)
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                renders.append(png)
                if let directory {
                    try png.write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("\(appearance.rawValue)-\(visible ? "held" : "idle").png"))
                }
            }
            #expect(sizes[0] == sizes[1])
            #expect(renders[0] != renders[1])
        }
    }

    private func event(_ code: UInt16, _ characters: String,
                       _ flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
}
