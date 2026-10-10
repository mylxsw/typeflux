import AppKit
import Testing
@testable import Typeflux

extension AskQuickResultsInteractionTests {
    @Test func `native command number shortcut runs once without typing A digit`() async throws {
        try await withPasteboard { pasteboard in
            let launcher = try await Launcher(text: "1234567.89*2")
            defer { launcher.close() }
            launcher.window.makeKeyAndOrderFront(nil)
            launcher.window.makeFirstResponder(launcher.editor)
            @MainActor func event(repeated: Bool) throws -> NSEvent {
                try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                              windowNumber: launcher.window.windowNumber, context: nil, characters: "2",
                                              charactersIgnoringModifiers: "2", isARepeat: repeated, keyCode: 19))
            }
            #expect(try launcher.editor.performKeyEquivalent(with: event(repeated: true)))
            #expect(launcher.dismissed == 0 && pasteboard.string(forType: .string) == nil)
            #expect(try launcher.editor.performKeyEquivalent(with: event(repeated: false)))
            #expect(pasteboard.string(forType: .string) == "2,469,135.78")
            #expect(launcher.dismissed == 1 && launcher.fixture.model.launcherDraft.text.isEmpty)
        }
    }

    @Test func `command number opens the corresponding app instead of the highlight`() async throws {
        try await withPasteboard { _ in
            let apps = AskTestAppIndex([AskTestAppIndex.app("Tool Alpha"), AskTestAppIndex.app("Tool Beta")])
            let launcher = try await Launcher(text: "tool", apps: apps)
            defer { launcher.close() }
            let results = try #require(launcher.fixture.model.quickSearch.results)
            let index = try #require(results.rows.firstIndex(of: .app(1)))
            let code = [UInt16(18), 19, 20, 21, 23, 22, 26, 28, 25][index]
            try await launcher.press(code, .command)
            #expect(launcher.opened == [results.apps[1].entry.url])
            #expect(launcher.dismissed == 1)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func `command number copies another calculation format`() async throws {
        try await withPasteboard { pasteboard in
            let launcher = try await Launcher(text: "1234567.89*2")
            defer { launcher.close() }
            try await launcher.press(19, .command)
            #expect(pasteboard.string(forType: .string) == "2,469,135.78")
            #expect(launcher.dismissed == 1)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func `a missing number leaves the result and draft alone`() async throws {
        try await withPasteboard { pasteboard in
            let launcher = try await Launcher(text: "1+1")
            defer { launcher.close() }
            try await launcher.press(25, .command)
            #expect(launcher.fixture.model.launcherDraft.text == "1+1")
            #expect(launcher.dismissed == 0)
            #expect(pasteboard.string(forType: .string) == nil)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func `command number enters the chosen plugin list item`() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "prefix")
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await launcher.press(Self.returnKey)
            try await AskQuickSearchSessionTests.wait { model.plugins.output?.items.isEmpty == false }
            #expect(model.plugins.output?.items[1].title == "dict")
            try await launcher.press(19, .command)
            #expect(model.plugins.keyword?.keyword == "dict")
            #expect(model.launcherDraft.text.isEmpty && model.plugins.phase == .waiting)
            #expect(launcher.dismissed == 0)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func `command number cannot run A disabled plugin item`() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "prefix off", prepare: { model in
                model.modelLibrary.settings.saveAskLauncherKeywords(AskPrefixPlugin.keywords + [
                    AskKeyword(keyword: "off", pluginID: AskWebSearchPlugin.id, enabled: false)
                ])
            })
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await AskQuickSearchSessionTests.wait { model.plugins.output?.items.count == 1 }
            try await launcher.press(18, .command)
            #expect(model.plugins.keyword?.pluginID == AskPrefixPlugin.id)
            #expect(launcher.dismissed == 0)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func `number after the plugin items asks the AI`() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "prefix fixture-web", prepare: { model in
                model.modelLibrary.settings.saveAskLauncherKeywords(AskPrefixPlugin.keywords + [
                    AskKeyword(keyword: "fixture-web", pluginID: AskWebSearchPlugin.id)
                ])
            })
            defer { launcher.close() }
            try await AskQuickSearchSessionTests.wait { launcher.fixture.model.plugins.output?.items.count == 1 }
            try await launcher.press(19, .command)
            #expect(try await launcher.sentCount() == 1)
        }
    }
}
