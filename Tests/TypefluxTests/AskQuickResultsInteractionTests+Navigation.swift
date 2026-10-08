import AppKit
import Testing
@testable import Typeflux

extension AskQuickResultsInteractionTests {
    @Test func settingReturnOpensApplicationSystemSettings() async throws {
        try await withPasteboard { _ in
            var sections: [StudioSection] = []
            let launcher = try await Launcher(text: "setting", selection: "Selected", prepare: { model in
                model.onOpenSettings = { sections.append($0) }
            })
            defer { launcher.close() }
            try await launcher.press(Self.returnKey)
            #expect(sections == [.settings] && launcher.dismissed == 1)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func historyReturnListsChatsAndReturnOpensOneWithoutSending() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "history", selection: "Unrelated selection", prepare: { model in
                _ = model.credentials()
            })
            defer { launcher.close() }
            let model = launcher.fixture.model
            await launcher.fixture.api.seed(.init(id: "chat", title: "A project", revision: 1, updatedAt: Date(), messages: []))
            try await launcher.fixture.cache.save(.init(id: "chat", title: "A project", revision: 1, updatedAt: Date(), messages: []), owner: "owner")
            var opens = 0
            model.onShowConversation = { opens += 1 }
            try await launcher.press(Self.returnKey)
            try await AskQuickSearchSessionTests.wait { model.plugins.output?.items.count == 1 }
            #expect(model.plugins.keyword?.pluginID == AskHistoryPlugin.id && model.plugins.request?.text == "")
            #expect(model.plugins.request?.selection == nil)
            try await launcher.press(Self.returnKey)
            try await launcher.fixture.wait { model.selected?.id == "chat" }
            #expect(opens == 1 && launcher.dismissed == 1)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func historyQueryFiltersWhileTypingAndDisabledSettingDoesNotOpen() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "history", prepare: { model in
                _ = model.credentials()
            })
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await launcher.fixture.cache.save(.init(id: "one", title: "项目规划", revision: 1, updatedAt: Date(), messages: []), owner: "owner")
            try await launcher.fixture.cache.save(.init(id: "two", title: "Weekend", revision: 1, updatedAt: Date(), messages: []), owner: "owner")
            try await launcher.press(Self.returnKey)
            try await AskQuickSearchSessionTests.wait { model.plugins.output?.items.count == 2 }
            launcher.editor.insertText("项目", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await AskQuickSearchSessionTests.wait { model.plugins.output?.items.count == 1 }
            #expect(model.plugins.output?.items.first?.id == "one")
            launcher.editor.selectAll(nil)
            launcher.editor.insertText("week", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await AskQuickSearchSessionTests.wait { model.plugins.output?.original == "week" }
            #expect(model.plugins.output?.items.first?.id == "two")
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
        let f = try AskTestFixture()
        var keyword = AskSettingsPlugin.keywords[0]
        keyword.enabled = false
        f.model.modelLibrary.settings.saveAskLauncherKeywords([keyword])
        #expect(AskKeywordMatcher.match("setting", keywords: f.model.launcherKeywords) == nil)
    }
}
