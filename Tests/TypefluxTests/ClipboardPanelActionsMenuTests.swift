import AppKit
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct ClipboardPanelActionsMenuTests {
    @Test func entryActionsKeepTheirIdentityWhenSelectionMoves() throws {
        TypefluxTestApplicationEnvironment.prepare()
        let model = ClipboardPanelModel()
        let first = ClipboardTestSupport.entry(.text, text: "First")
        let second = ClipboardTestSupport.entry(.text, text: "Second")
        model.reset(entries: [first, second])
        var pasted: [String] = []
        model.onAction = { action, entry in
            #expect(action == .paste)
            pasted.append(entry.id)
        }
        let presenter = ClipboardPanelActionsMenu(model: model)
        let menu = presenter.makeMenu()
        let paste = try #require(menu.items.first { $0.title == ClipboardEntryAction.paste.title(for: first) })
        #expect(paste.keyEquivalent == "\r" && paste.keyEquivalentModifierMask.isEmpty)
        let plain = try #require(menu.items.first { $0.title == ClipboardEntryAction.pastePlainText.title(for: first) })
        #expect(plain.keyEquivalent == "\r" && plain.keyEquivalentModifierMask == .command)
        model.select(index: 1)
        #expect(NSApp.sendAction(try #require(paste.action), to: paste.target, from: paste))
        #expect(pasted == [first.id])
        model.replaceEntries([second])
        #expect(NSApp.sendAction(try #require(paste.action), to: paste.target, from: paste))
        #expect(pasted == [first.id], "A removed entry must not redirect its action to another row")
    }

    @Test func missingContentIsDisabledButManagementRemainsAvailable() throws {
        TypefluxTestApplicationEnvironment.prepare()
        let model = ClipboardPanelModel()
        let entry = ClipboardTestSupport.entry(.image, imagePath: "/missing.png")
        model.fileExists = { _ in false }
        model.reset(entries: [entry])
        let presenter = ClipboardPanelActionsMenu(model: model)
        let menu = presenter.makeMenu()
        for action in model.actions(for: entry) {
            let item = try #require(menu.items.first { $0.title == action.title(for: entry) })
            #expect(item.isEnabled == !action.requiresContent)
        }
        let pin = try #require(menu.items.first { $0.title == ClipboardEntryAction.togglePin.title(for: entry) })
        var performed: [ClipboardEntryAction] = []
        model.onAction = { action, _ in performed.append(action) }
        #expect(NSApp.sendAction(try #require(pin.action), to: pin.target, from: pin))
        #expect(performed == [.togglePin])
    }

    @Test func panelActionsWorkWithoutResultsAndClearStillRequiresConfirmation() throws {
        TypefluxTestApplicationEnvironment.prepare()
        let model = ClipboardPanelModel()
        var commands: [ClipboardPanelCommand] = []
        model.onCommand = { commands.append($0) }
        let presenter = ClipboardPanelActionsMenu(model: model)
        let empty = presenter.makeMenu()
        for title in [L("clipboard.toolbar.pause"), L("clipboard.toolbar.settings"), L("clipboard.menu.showPreview")] {
            let item = try #require(empty.items.first { $0.title == title })
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        }
        #expect(commands == [.togglePause, .openSettings])
        #expect(model.showsPreview)
        model.reset(entries: [ClipboardTestSupport.entry(.text, text: "Delete after confirmation")])
        let menu = presenter.makeMenu()
        let clear = try #require(menu.items.first { $0.title == L("clipboard.menu.clearUnpinned") })
        #expect(NSApp.sendAction(try #require(clear.action), to: clear.target, from: clear))
        #expect(model.pendingConfirmation == .clearUnpinned(count: 1))
        #expect(commands == [.togglePause, .openSettings])
        model.cancelPending()
        #expect(model.pendingConfirmation == nil)
    }

    @Test func compactMetadataUsesSourceTimeAndSnippetRetention() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let time = L("clipboard.time.justNow")
        for source in [String?.none, "", "Notes"] {
            let entry = ClipboardTestSupport.entry(.text, date: now, text: "Text", sourceAppName: source)
            #expect(ClipboardEntryFormatter.rowMetadata(for: entry, now: now)
                    == (source == "Notes" ? "Notes · " + time : time))
        }
        let voice = ClipboardTestSupport.entry(.voice, date: now, text: "Voice", sourceAppName: "Ignored")
        #expect(ClipboardEntryFormatter.rowMetadata(for: voice, now: now) == "Typeflux · " + time)
        var snippet = ClipboardTestSupport.entry(.text, text: "Snippet")
        snippet.snippet = ClipboardSnippet(name: "Signature", alias: "signature")
        #expect(ClipboardEntryFormatter.rowMetadata(for: snippet) == L("clipboard.tab.snippet"))
        var pinnedSnippet = ClipboardTestSupport.entry(.text, text: "Snippet", isPinned: true)
        pinnedSnippet.snippet = snippet.snippet
        #expect(ClipboardEntryFormatter.rowMetadata(for: pinnedSnippet)
                == L("clipboard.tab.snippet") + " · " + L("clipboard.section.pinned"))
    }
}
