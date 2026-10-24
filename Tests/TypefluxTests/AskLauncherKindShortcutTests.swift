import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Launcher mode shortcuts", .serialized, .exclusiveUIState)
@MainActor
struct AskLauncherKindShortcutTests {
    @Test func modeKeyRequiresCommandMAndLeavesCopyAndCloseAlone() throws {
        for text in ["m", "M", ""] {
            #expect(AskLauncherKindShortcuts.matches(try event(46, text)))
        }
        for flags: NSEvent.ModifierFlags in [[], .shift, [.command, .shift], [.command, .option], [.command, .control]] {
            #expect(!AskLauncherKindShortcuts.matches(try event(46, "m", flags)))
        }
        for (code, text) in [(UInt16(8), "c"), (13, "w"), (0, "")] {
            #expect(!AskLauncherKindShortcuts.matches(try event(code, text)))
        }
    }

    @Test func nativeModeToggleWorksInBothEditorsAndRespectsMarkedText() throws {
        let window = AskTestVoiceWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                                        styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = AskComposerTextView.Editor()
        window.contentView = editor
        window.makeFirstResponder(editor)
        var toggles = 0
        editor.onKindShortcut = { toggles += 1 }
        for context in ["launcher", "chat:new"] {
            editor.contextID = context
            #expect(editor.performKeyEquivalent(with: try event(46, "m")))
            editor.keyDown(with: try event(46, "m"))
        }
        #expect(toggles == 4)
        #expect(!editor.performKeyEquivalent(with: try event(13, "w")))
        editor.setMarkedText("draft", selectedRange: NSRange(location: 0, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!editor.performKeyEquivalent(with: try event(46, "m")))
        #expect(toggles == 4)
    }

    @Test(arguments: ["", "An unsent question"])
    func launcherRoutesModeKeysWithoutClosingOrSubmittingItsDraft(text: String) async throws {
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: text)
        defer { launcher.close() }
        launcher.fixture.model.setConversationKind(.chat, launcher: true)
        launcher.window.makeFirstResponder(launcher.editor)
        #expect(launcher.editor.performKeyEquivalent(with: try event(46, "m")))
        #expect(launcher.fixture.model.conversationKind(launcher: true) == .work)
        try await launcher.press(46, .command)
        #expect(launcher.fixture.model.conversationKind(launcher: true) == .chat)
        #expect(launcher.fixture.model.launcherDraft.text == text)
        #expect(launcher.dismissed == 0)
        #expect(await launcher.fixture.api.sends.isEmpty)
    }

    @Test(arguments: ["", "An unsent question"])
    func windowShortcutTogglesRepeatedlyWithAndWithoutEditorFocus(text: String) async throws {
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: text)
        defer { launcher.close() }
        let model = launcher.fixture.model
        model.setConversationKind(.chat, launcher: true)
        for editorFocused in [false, true] {
            launcher.window.makeFirstResponder(editorFocused ? launcher.editor : nil)
            for index in 0 ..< 6 {
                let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: Double(index), windowNumber: launcher.window.windowNumber, context: nil,
                    characters: "m", charactersIgnoringModifiers: "m", isARepeat: false, keyCode: 46))
                #expect(launcher.window.performKeyEquivalent(with: key))
                #expect(model.conversationKind(launcher: true) == (index.isMultiple(of: 2) ? .work : .chat))
                // Include both rapid presses before a redraw and presses after it.
                if index.isMultiple(of: 2) {
                    try await Task.sleep(for: .milliseconds(60))
                    launcher.window.contentView?.layoutSubtreeIfNeeded()
                }
            }
        }
        #expect(model.launcherDraft.text == text)
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
