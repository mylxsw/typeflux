import AppKit
import Testing
@testable import Typeflux

@Suite("Ask slash parsing")
struct AskSlashQueryTests {
    @Test func aSlashCountsOnlyAtTheStartOrAfterWhitespace() {
        #expect(AskSlashQuery.parse("/", caret: 1) == AskSlashQuery(range: NSRange(location: 0, length: 1), name: "", argument: nil))
        #expect(AskSlashQuery.parse("hello /mo", caret: 9)?.name == "mo")
        #expect(AskSlashQuery.parse("hello /mo", caret: 9)?.range == NSRange(location: 6, length: 3))
        #expect(AskSlashQuery.parse("line\n/think", caret: 11)?.name == "think")
        #expect(AskSlashQuery.parse("a/b", caret: 3) == nil)
        #expect(AskSlashQuery.parse("/usr/bin", caret: 8) == nil)
        #expect(AskSlashQuery.parse("plain text", caret: 10) == nil)
        #expect(AskSlashQuery.parse("/mo", caret: 9) == nil, "a caret past the end is ignored")
    }

    @Test func aSpaceStartsTheArgument() {
        let query = AskSlashQuery.parse("/model gpt 5", caret: 12)
        #expect(query?.name == "model")
        #expect(query?.argument == "gpt 5")
        #expect(AskSlashQuery.parse("/remember ", caret: 10)?.argument == "")
        #expect(AskSlashQuery.parse("/mo\n", caret: 4) == nil, "a new line ends the token")
    }

    @Test func theChineseSlashKeyOpensCommandsToo() {
        #expect(AskSlashQuery.parse("、mo", caret: 3)?.name == "mo")
        #expect(AskSlashQuery.parse("苹果、香蕉", caret: 5) == nil, "a list separator inside text is not a command")
    }

    @Test func onlyTheTextBeforeTheCaretCounts() {
        #expect(AskSlashQuery.parse("/model and more", caret: 3)?.name == "mo")
        #expect(AskSlashQuery.parse("/中文", caret: 3)?.name == "中文")
    }

    @Test func replacingKeepsTheRestOfTheText() {
        let query = AskSlashQuery.parse("ask /mo", caret: 7)!
        #expect(query.replacing(in: "ask /mo", with: "/model ") == "ask /model ")
        #expect(query.replacing(in: "ask /mo", with: "") == "ask ")
        #expect(query.replacing(in: "x", with: "y") == "x", "a stale range leaves the text alone")
    }

    @Test @MainActor func keysMapFromEvents() throws {
        func event(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        #expect(AskCommandKey(event(126)) == .up)
        #expect(AskCommandKey(event(125)) == .down)
        #expect(AskCommandKey(event(36)) == .enter)
        #expect(AskCommandKey(event(76)) == .enter)
        #expect(AskCommandKey(event(48)) == .tab)
        #expect(AskCommandKey(event(53)) == .escape)
        #expect(AskCommandKey(event(36, .shift)) == nil, "shift-return is a new line")
        #expect(AskCommandKey(event(36, .command)) == .commandEnter)
        #expect(AskCommandKey(event(76, .command)) == .commandEnter)
        #expect(AskCommandKey(event(36, [.command, .shift])) == nil)
        #expect(AskCommandKey(event(48, .command)) == nil)
        #expect(AskCommandKey(event(0)) == nil)
    }
}

@Suite("Ask command catalog")
struct AskCommandCatalogTests {
    private var context: AskCommandContext {
        var context = AskCommandContext()
        context.models = [.init(reference: "cloud:a", name: "Model A", vision: true), .init(reference: "custom:b", name: "Model B", vision: false)]
        context.currentModel = "cloud:a"
        context.reasoningAvailable = true
        context.hasAnswer = true
        context.selectionAvailable = true
        context.skills = [AskSkillSummary(name: "meeting-notes", description: "Notes", builtin: true),
                          AskSkillSummary(name: "new", description: "Clashes with /new", builtin: false)]
        context.mcpServers = [AskMCPServerSummary(name: "github", enabled: true), AskMCPServerSummary(name: "notion", enabled: false)]
        return context
    }

    private func command(_ name: String, in context: AskCommandContext) -> AskCommand? {
        AskCommandCatalog.commands(context).first { $0.name == name }
    }

    @Test func everyGroupIsPresentInOrder() {
        let commands = AskCommandCatalog.commands(context)
        let groups = commands.map(\.group).reduce(into: [AskCommand.Group]()) { if $0.last != $1 { $0.append($1) } }
        #expect(groups == [.conversation, .model, .context, .prompts, .skills, .mcp, .other])
        #expect(Set(commands.map(\.id)).count == commands.count)
        for group in AskCommand.Group.allCases { #expect(!group.title.isEmpty) }
    }

    @Test func availabilityFollowsTheContext() {
        var busy = context
        busy.busy = true
        #expect(command("model", in: busy)?.enabled == false)
        #expect(command("regenerate", in: busy)?.enabled == false)
        #expect(command("new", in: busy)?.enabled == true)
        var empty = context
        empty.hasAnswer = false
        empty.selectionAvailable = false
        empty.reasoningAvailable = false
        empty.screenshotUnavailable = "No vision"
        #expect(command("copy", in: empty)?.enabled == false)
        #expect(command("selection", in: empty)?.disabledReason == L("ask.command.disabled.noSelection"))
        #expect(command("think", in: empty) == nil)
        #expect(command("screenshot", in: empty)?.disabledReason == "No vision")
        #expect(command("explain-screen", in: empty)?.enabled == false)
        empty.screenshotOn = true
        #expect(command("screenshot", in: empty)?.enabled == true, "an attached screenshot can always be removed")
        var launcher = context
        launcher.launcher = true
        #expect(command("regenerate", in: launcher)?.enabled == false)
        #expect(command("notion", in: context)?.enabled == false)
    }

    @Test func togglesShowTheirStateAndChoicesTheirSelection() {
        var chosen = context
        chosen.memoryOn = false
        chosen.chosenSkills = ["meeting-notes"]
        chosen.chosenServers = ["github"]
        #expect(command("memory", in: chosen)?.kind == .toggle(on: false))
        #expect(command("meeting-notes", in: chosen)?.selected == true)
        #expect(command("github", in: chosen)?.selected == true)
        #expect(command("model", in: chosen)?.trailing == "Model A")
        #expect(command("meeting-notes", in: chosen)?.badge == L("ask.command.badge.builtin"))
    }

    @Test func namesThatClashWithBuiltInsArePrefixed() {
        let commands = AskCommandCatalog.commands(context)
        #expect(commands.filter { $0.name == "new" }.count == 1)
        #expect(commands.contains { $0.name == "skill:new" && $0.action == .skill("new") })
        let clash = AskCommandCatalog.disambiguated([
            AskCommand(action: .search, name: "search", title: "", symbol: "", group: .conversation),
            AskCommand(action: .mcpServer("search"), name: "search", title: "", symbol: "", group: .mcp)
        ])
        #expect(clash.map(\.name) == ["search", "mcp:search"])
    }

    @Test func submenusListModelsAndReasoningLevels() {
        let models = AskCommandCatalog.submenu(.model, context: context)
        #expect(models.map(\.name) == ["Model A", "Model B"])
        #expect(models.first?.selected == true)
        #expect(models.allSatisfy { $0.plain })
        #expect(models.first?.detail == L("ask.command.model.vision"))
        let levels = AskCommandCatalog.submenu(.reasoning, context: context)
        // "Auto" plus the levels the current model offers.
        #expect(levels.count == 1 + context.reasoningLevels.count)
        #expect(levels.first?.selected == true)
        #expect(AskCommandCatalog.submenu(.help, context: context).isEmpty)
    }

    @Test func promptNamesAreReadable() {
        #expect(AskCommandCatalog.promptName("ask.suggest.screen") == "explain-screen")
        #expect(AskCommandCatalog.promptName("ask.suggest.selection") == "translate")
        #expect(AskCommandCatalog.promptName("ask.suggest.page") == "summarize-page")
        #expect(AskCommandCatalog.promptName("ask.suggest.other") == "other")
    }

    @Test func recentCommandsLeadOnce() {
        let commands = AskCommandCatalog.commands(context)
        let listed = AskCommandCatalog.withRecent(commands, recent: ["model", "gone", "new"])
        #expect(listed.prefix(2).map(\.name) == ["model", "new"])
        #expect(listed.prefix(2).allSatisfy { $0.group == .recent })
        #expect(listed.count == commands.count + 2)
    }
}

@Suite("Ask command matching")
struct AskCommandMatcherTests {
    private let commands = [
        AskCommand(action: .model, name: "model", title: "Switch model", symbol: "", group: .model, aliases: ["moxing"]),
        AskCommand(action: .memory, name: "memory", title: "Use memory", symbol: "", group: .context),
        AskCommand(action: .suggestion("s"), name: "explain-screen", title: "Explain", symbol: "", group: .prompts),
        AskCommand(action: .screenshot, name: "screenshot", title: "Attach the screenshot", symbol: "", group: .context)
    ]

    @Test func prefixesBeatWordsBeatTitlesBeatScatteredLetters() {
        // "model" starts with it; "memory" only has it inside its title.
        #expect(AskCommandMatcher.filter(commands, query: "mo").map(\.command.name) == ["model", "memory"])
        let screen = AskCommandMatcher.filter(commands, query: "scr")
        #expect(screen.map(\.command.name) == ["screenshot", "explain-screen"])
        #expect(screen[1].highlights == [8, 9, 10])
        #expect(AskCommandMatcher.filter(commands, query: "moxing").map(\.command.name) == ["model"])
        #expect(AskCommandMatcher.filter(commands, query: "Switch").map(\.command.name) == ["model"])
        let scattered = AskCommandMatcher.filter(commands, query: "mmy")
        #expect(scattered.map(\.command.name) == ["memory"])
        #expect(scattered.first?.highlights == [0, 2, 5])
        #expect(AskCommandMatcher.filter(commands, query: "zzz").isEmpty)
    }

    @Test func anEmptyQueryKeepsTheCatalogOrder() {
        #expect(AskCommandMatcher.filter(commands, query: "").map(\.command.name) == commands.map(\.name))
    }

    @Test func duplicatesFromRecentAreListedOnceWhenSearching() {
        var recent = commands[0]
        recent.group = .recent
        #expect(AskCommandMatcher.filter([recent] + commands, query: "mod").count == 1)
    }
}

@Suite("Ask command palette navigation")
struct AskCommandPaletteStateTests {
    private func rows(_ enabled: [Bool]) -> [AskCommandMatcher.Match] {
        enabled.enumerated().map { index, on in
            AskCommandMatcher.Match(command: AskCommand(action: .help, name: "c\(index)", title: "", symbol: "", group: .other,
                                                        disabledReason: on ? nil : "off"), score: 1, highlights: [])
        }
    }

    @Test func arrowsWrapAndSkipDisabledRows() {
        var state = AskCommandPaletteState()
        state.update(rows: rows([false, true, false, true]))
        #expect(state.highlighted == 1)
        state.move(1)
        #expect(state.highlighted == 3)
        state.move(1)
        #expect(state.highlighted == 1)
        state.move(-1)
        #expect(state.highlighted == 3)
        #expect(state.highlightedCommand?.name == "c3")
    }

    @Test func aNewQueryHighlightsTheBestMatch() {
        var state = AskCommandPaletteState()
        state.update(rows: rows([true, true, true]), query: "m")
        state.move(1)
        #expect(state.highlighted == 1)
        state.update(rows: rows([true, true, true]), query: "me")
        #expect(state.highlighted == 0)
        state.move(1)
        let submenu = AskCommand(action: .model, name: "model", title: "", symbol: "", group: .model)
        state.update(rows: rows([true, true]), query: "me", parent: submenu)
        #expect(state.highlighted == 0, "opening a submenu starts at its first choice")
        #expect(state.parent == submenu)
        #expect(state.query == "me")
    }

    @Test func theHighlightFollowsItsRowAcrossUpdates() {
        var state = AskCommandPaletteState()
        state.update(rows: rows([true, true, true]))
        state.move(1)
        state.move(1)
        state.update(rows: Array(rows([true, true, true]).suffix(2)))
        #expect(state.highlightedCommand?.name == "c2")
        state.update(rows: [])
        #expect(state.highlightedCommand == nil)
        state.move(1)
        #expect(state.highlighted == 0)
        var allOff = AskCommandPaletteState()
        allOff.update(rows: rows([false, false]))
        #expect(allOff.highlighted == 0)
    }

    @Test func paletteHeightGrowsWithRowsUpToItsLimit() {
        var state = AskCommandPaletteState()
        state.update(rows: rows([true]))
        let one = AskCommandPaletteView.height(for: state)
        #expect(one == AskCommandPaletteView.chromeHeight + AskCommandPaletteView.rowHeight + AskCommandPaletteView.groupHeight)
        state.update(rows: rows(Array(repeating: true, count: 40)))
        #expect(AskCommandPaletteView.height(for: state) == AskCommandPaletteView.chromeHeight + AskCommandPaletteView.maximumListHeight)
        state.parent = AskCommand(action: .model, name: "model", title: "", symbol: "", group: .model)
        #expect(AskCommandPaletteView.groupStarts(state).isEmpty)
    }

    @Test func compactPaletteLeavesSpaceForTheEditorInShortWindows() {
        var state = AskCommandPaletteState()
        #expect(AskCommandPaletteView.height(for: state, compact: true) == 24)
        state.update(rows: rows([true]))
        #expect(AskCommandPaletteView.height(for: state, compact: true) == 68)
        state.update(rows: rows(Array(repeating: true, count: 40)))
        #expect(AskCommandPaletteView.height(for: state, compact: true) == 68)
        state.move(1)
        #expect(state.highlightedCommand?.name == "c1")
        #expect(state.rows.count == 40)
        #expect(AskCommandPaletteView.height(for: state) > 68)
        #expect(AskCommandPaletteView.height(for: state, compact: true, maximumHeight: 112) == 112)
        #expect(AskCommandPaletteView.height(for: state, maximumHeight: 200) == 200)
        #expect(AskCommandPaletteView.height(for: state, compact: true, maximumHeight: 1000) == 324)
    }
}

@Suite("Ask command execution")
@MainActor
struct AskCommandExecutionTests {
    private func command(_ action: AskCommandAction, _ name: String, kind: AskCommand.Kind = .action) -> AskCommand {
        AskCommand(action: action, name: name, title: "", symbol: "", group: .other, kind: kind)
    }

    private func fixture() throws -> (AskTestFixture, Recorder) {
        let f = try AskTestFixture()
        let recorder = Recorder()
        f.model.commandSources = AskCommandSources(
            skills: { [AskSkill(name: "meeting-notes", description: "Notes", body: "Decisions first.")] },
            mcpServers: { [AskMCPServerSummary(name: "github", enabled: true)] },
            remember: { text in
                if text == "fail" { throw AskLocalError.message("Memory is full") }
                recorder.notes.append(text)
            },
            privateByDefault: { recorder.local },
            copy: { recorder.copied = $0 }
        )
        return (f, recorder)
    }

    final class Recorder {
        var notes: [String] = []
        var local = false
        var copied: String?
    }

    @Test func togglesChangeTheDraftAndConfirm() throws {
        let (f, recorder) = try fixture()
        f.model.draft.selection = "words"
        f.model.runCommand(command(.selection, "selection"), launcher: false)
        #expect(f.model.draft.selectionOff == true)
        #expect(f.model.commandFeedback == L("ask.command.selectionOff"))
        f.model.runCommand(command(.selection, "selection"), launcher: false)
        #expect(f.model.draft.selectionOff == nil)
        let memory = f.model.memorySwitchedOff(launcher: false)
        f.model.runCommand(command(.memory, "memory"), launcher: false)
        #expect(f.model.memorySwitchedOff(launcher: false) != memory)
        f.model.runCommand(command(.localMode, "local"), launcher: false)
        #expect(f.model.storesLocally(launcher: false) && !recorder.local)
        #expect(f.model.commandFeedback == L("ask.command.localOn"))
        #expect(f.model.recentCommands.prefix(3) == ["local", "memory", "selection"])
    }

    @Test func screenshotToggleRespectsTheModel() throws {
        let (f, _) = try fixture()
        f.model.draft.includeScreenshot = true
        f.model.runCommand(command(.screenshot, "screenshot"), launcher: false)
        #expect(!f.model.draft.includeScreenshot)
        f.model.runCommand(command(.screenshot, "screenshot"), launcher: false)
        #expect(f.model.draft.includeScreenshot == (f.model.screenshotCapability(launcher: false) == .supported))
    }

    @Test func skillAndServerChipsToggleWithinTheirLimits() throws {
        let (f, _) = try fixture()
        f.model.runCommand(command(.skill("meeting-notes"), "meeting-notes", kind: .token), launcher: true)
        #expect(f.model.launcherDraft.skills == ["meeting-notes"])
        f.model.runCommand(command(.skill("meeting-notes"), "meeting-notes", kind: .token), launcher: true)
        #expect(f.model.launcherDraft.skills == nil)
        for index in 0 ... AskConversationModel.maximumChosenServers {
            f.model.runCommand(command(.mcpServer("s\(index)"), "s\(index)", kind: .token), launcher: false)
        }
        #expect(f.model.draft.mcpServers?.count == AskConversationModel.maximumChosenServers)
        #expect(f.model.commandFeedback == L("ask.command.tooManyChoices", AskConversationModel.maximumChosenServers))
        f.model.removeChoice(mcpServer: "s0", launcher: false)
        #expect(f.model.draft.mcpServers?.contains("s0") == false)
        f.model.draft.skills = ["meeting-notes"]
        f.model.removeChoice(skill: "meeting-notes", launcher: false)
        #expect(f.model.draft.skills == nil)
    }

    @Test func chosenSkillsTravelWithTheirInstructions() async throws {
        let (f, _) = try fixture()
        #expect(f.model.skillUses(nil) == nil)
        #expect(f.model.skillUses(["missing"]) == nil)
        f.model.draft.text = "Summarize the call"
        f.model.draft.skills = ["meeting-notes", "missing"]
        f.model.draft.mcpServers = ["github"]
        f.model.submitDraft()
        try await f.wait { !(f.model.selected?.messages.isEmpty ?? true) }
        try await f.wait { !f.model.isBusy }
        let sent = await f.api.sends.last
        #expect(sent?.skills == [AskSkillUse(name: "meeting-notes", instructions: "Decisions first.")])
        #expect(sent?.mcpServers == ["github"])
        #expect(f.model.selected?.messages.first?.skills?.count == 1)
    }

    @Test func rememberCopyAndSuggestionsUseTheirSources() throws {
        let (f, recorder) = try fixture()
        f.model.runCommand(command(.remember, "remember", kind: .argument), argument: "  I prefer Go  ", launcher: false)
        #expect(recorder.notes == ["I prefer Go"])
        #expect(f.model.commandFeedback == L("ask.command.remembered"))
        f.model.runCommand(command(.remember, "remember", kind: .argument), argument: " ", launcher: false)
        #expect(recorder.notes.count == 1)
        f.model.runCommand(command(.remember, "remember", kind: .argument), argument: "fail", launcher: false)
        #expect(f.model.error == "Memory is full")

        f.model.runCommand(command(.copyAnswer, "copy"), launcher: false)
        #expect(recorder.copied == nil, "nothing to copy yet")
        f.model.draft.text = "Please"
        f.model.runCommand(command(.suggestion("ask.suggest.page"), "summarize-page"), launcher: false)
        #expect(f.model.draft.text == "Please " + L("ask.suggest.page"))
        f.model.runCommand(command(.suggestion("unknown"), "x"), launcher: false)
        #expect(f.model.draft.text == "Please " + L("ask.suggest.page"))
    }

    @Test func conversationCommandsReachTheWindow() async throws {
        let (f, recorder) = try fixture()
        var shown = 0
        var opened: StudioSection?
        f.model.onShowConversation = { shown += 1 }
        f.model.onOpenSettings = { opened = $0 }
        f.model.runCommand(command(.search, "search"), launcher: true)
        #expect(f.model.searchRequest == 1)
        #expect(shown == 1)
        f.model.runCommand(command(.newConversation, "new"), launcher: true)
        #expect(shown == 2)
        #expect(f.model.selectedId == nil)
        f.model.runCommand(command(.settings, "settings"), launcher: false)
        #expect(opened == .agent)
        f.model.runCommand(command(.pickReasoning(.high), "High"), launcher: false)
        #expect(f.model.reasoningEffort == .high)

        f.model.draft.text = "Question"
        f.model.submitDraft()
        try await f.wait { f.model.latestAnswer != nil && !f.model.isBusy }
        f.model.runCommand(command(.copyAnswer, "copy"), launcher: false)
        #expect(recorder.copied == "This is the answer.")
        #expect(f.model.commandContext(launcher: false).hasAnswer)
        f.model.runCommand(command(.regenerate, "regenerate"), launcher: false)
        try await f.wait { !f.model.isBusy }
    }

    @Test func disabledCommandsDoNothing() throws {
        let (f, _) = try fixture()
        var disabled = command(.newConversation, "new")
        disabled.disabledReason = "No"
        f.model.draft.text = "keep"
        f.model.runCommand(disabled, launcher: false)
        #expect(f.model.draft.text == "keep")
        #expect(f.model.recentCommands.isEmpty)
    }

    @Test func theContextReflectsTheModelAndSources() throws {
        let (f, recorder) = try fixture()
        recorder.local = true
        f.model.launcherDraft.skills = ["meeting-notes"]
        let context = f.model.commandContext(launcher: true)
        #expect(context.launcher)
        #expect(context.localMode)
        #expect(context.skills.map(\.name) == ["meeting-notes"])
        #expect(context.mcpServers.map(\.name) == ["github"])
        #expect(context.chosenSkills == ["meeting-notes"])
        #expect(!context.models.contains { $0.reference.hasPrefix("cloud:") })
        recorder.local = false
        #expect(f.model.commandContext(launcher: true).models.contains { $0.reference == context.currentModel })
    }

    @Test func feedbackClearsItself() async throws {
        let (f, _) = try fixture()
        f.model.confirm("Done", for: .milliseconds(20))
        #expect(f.model.commandFeedback == "Done")
        try await f.wait { f.model.commandFeedback == nil }
    }
}

@Suite("Ask command prompts")
struct AskCommandPromptTests {
    @Test func chosenSkillsAndServersReachThePrompt() {
        #expect(AskLocalPrompt.choices(skills: nil, mcpServers: nil).isEmpty)
        let text = AskLocalPrompt.choices(skills: [AskSkillUse(name: "meeting-notes", instructions: "Decisions first.")],
                                          mcpServers: ["github", "notion"])
        #expect(text.contains("<skill name=\"meeting-notes\">\nDecisions first.\n</skill>"))
        #expect(text.contains("MCP servers where they apply: github, notion."))
        let message = AskMessage(id: "m", role: "user", text: "Go", createdAt: Date(), mcpServers: ["github"])
        #expect((AskLocalPrompt.message(message)["content"] as? String)?.contains("github") == true)
    }
}
