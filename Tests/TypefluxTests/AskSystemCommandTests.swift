import Foundation
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct AskSystemCommandTests {
    @Test func `commands have English keywords and recognize custom aliases`() {
        #expect(AskSystemCommand.allCases.count == 18)
        #expect(AskPluginRegistry.defaultKeywords
            .count(where: { AskSystemCommand(pluginID: $0.pluginID) != nil }) == 18)
        for command in AskSystemCommand.allCases {
            #expect(AskSystemCommand(pluginID: command.id) == command)
            #expect(AskKeywordKind(pluginID: command.id) == .system)
            #expect(!command.title.isEmpty && !command.symbol.isEmpty)
            #expect(AskSystemCommandPlugin(command: command).defaultKeywords.isEmpty)
        }
        #expect(AskSystemCommand(pluginID: "system.unknown") == nil)
        let alias = AskKeyword(keyword: "lock", pluginID: AskSystemCommand.lockScreen.id)
        let saved = AskPluginRegistry.keywords(saved: [alias], known: AskPluginRegistry.coveredGroups)
        #expect(saved == [alias])
        let session = AskPluginSession(plugins: [AskSystemCommandPlugin(command: .lockScreen)], keywords: { [alias] })
        #expect(session.detect(in: "lock ") == "")
        #expect(session.keyword == alias)
    }

    @Test func `command plans only act on explicit submission`() async {
        for command in AskSystemCommand.allCases {
            let plugin = AskSystemCommandPlugin(command: command)
            let keyword = AskKeyword(keyword: "custom", pluginID: command.id)
            let request = AskPluginRequest(
                text: "",
                origin: .argument,
                keyword: keyword,
                options: [:],
                interfaceLanguage: .english
            )
            let plan = await plugin.plan(request)
            #expect(plan.mode == .onSubmit)
            #expect(plan.action(for: .enter)?.kind == .systemCommand(command))
            #expect(plugin.runsWithoutInput && !plugin.usesSelectionInput)
        }
    }

    @Test func `keyword editor saves selected command and preserves options`() {
        var draft = AskKeywordDraft(adding: .system)
        #expect(!draft.canSave(among: [], workflows: []))
        draft.keyword = " lock "
        draft.systemCommand = .lockScreen
        #expect(draft.canSave(among: [], workflows: []))
        #expect(draft.result() == .init(keyword: "lock", pluginID: AskSystemCommand.lockScreen.id))
        #expect(!draft.canSave(among: [.init(keyword: "LOCK", pluginID: "prompt")], workflows: []))
        let alias = AskKeyword(keyword: "off", pluginID: AskSystemCommand.displaySleep.id, options: ["custom": "value"])
        let edited = AskKeywordDraft(editing: alias)
        #expect(edited.systemCommand == .displaySleep && edited.displayName == AskSystemCommand.displaySleep.title)
        #expect(edited.result() == alias)
        let rows = AskKeywordListPresentation.rows(keywords: [alias], interface: .english, secondLanguage: "en")
        #expect(rows.first?.kind == .system && rows.first?.name == AskSystemCommand.displaySleep.title)
    }

    @Test func `names are searchable in both languages and aliases are deduplicated`() {
        let command = AskSystemCommand.lockScreen
        let entries = ["lock", "ls"].map {
            AskLauncherSearchEntry(keyword: .init(keyword: $0, pluginID: command.id), title: command.title,
                                   detail: "", symbol: command.symbol, command: command)
        }
        #expect(AskLauncherSearchEntry.search(entries, text: "Lock Screen").count == 1)
        #expect(AskLauncherSearchEntry.search(entries, text: "锁定").count == 1)
        #expect(AskLauncherSearchEntry.search(entries, text: "ls").first?.keyword.keyword == "ls")
        let wifi = AskSystemCommand.toggleWiFi
        let wifiEntry = AskLauncherSearchEntry(keyword: .init(keyword: "", pluginID: wifi.id), title: wifi.title,
                                               detail: "", symbol: wifi.symbol, command: wifi)
        #expect(AskLauncherSearchEntry.search([wifiEntry], text: "wifi").count == 1)
    }

    @Test func `cancelling any system command preserves input and keyword state`() throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let process = RecordingProcess()
        fixture.model.systemCommandRunner = .init(process: process)
        var confirmations: [AskSystemCommand] = []
        fixture.model.confirmSystemCommand = {
            confirmations.append($0)
            return false
        }
        for command in AskSystemCommand.allCases {
            let keyword = AskKeyword(keyword: "custom", pluginID: command.id)
            fixture.model.plugins.enter(keyword)
            fixture.model.launcherDraft.text = "keep this input"
            let action = AskPluginAction(kind: .systemCommand(command), title: command.title, symbol: command.symbol)
            #expect(fixture.model.performPluginAction(action) == .stay)
            #expect(fixture.model.launcherDraft.text == "keep this input")
            #expect(fixture.model.plugins.keyword == keyword)
        }
        #expect(confirmations == AskSystemCommand.allCases)
        #expect(process.calls.isEmpty)
    }

    @Test(arguments: ["Display Sleep", "screenoff "])
    func `search and custom keywords require confirmation and only execute after acceptance`(text: String) async throws {
        let process = RecordingProcess()
        var accepted = false
        var confirmations: [AskSystemCommand] = []
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: text, prepare: { model in
            model.modelLibrary.settings.askLauncherKeywords = [
                .init(keyword: "screenoff", pluginID: AskSystemCommand.displaySleep.id)
            ]
            model.systemCommandRunner = .init(process: process)
            model.confirmSystemCommand = {
                confirmations.append($0)
                return accepted
            }
        })
        defer { launcher.close() }
        let draft = launcher.fixture.model.launcherDraft.text
        let keyword = launcher.fixture.model.plugins.keyword
        try await launcher.press(36)
        #expect(confirmations == [.displaySleep])
        #expect(process.calls.isEmpty && launcher.dismissed == 0)
        #expect(launcher.fixture.model.launcherDraft.text == draft)
        #expect(launcher.fixture.model.plugins.keyword == keyword)
        accepted = true
        try await launcher.press(36)
        try await launcher.fixture.wait { !process.calls.isEmpty }
        #expect(confirmations == [.displaySleep, .displaySleep])
        #expect(process.calls == [.init(executable: "/usr/bin/pmset", arguments: ["displaysleepnow"])])
        #expect(launcher.dismissed == 1 && launcher.fixture.model.launcherDraft.text.isEmpty)
    }

    @Test func `confirmation messages identify ordinary commands and preserve specific warnings`() {
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(previous) }
        for command in AskSystemCommand.allCases {
            #expect(!command.confirmationMessage.hasPrefix("ask.system."))
            #expect(!command.confirmationMessage.contains("%@"))
        }
        #expect(AskSystemCommand.toggleWiFi.confirmationMessage.contains(AskSystemCommand.toggleWiFi.title))
        #expect(AskSystemCommand.emptyTrash.confirmationMessage.contains("cannot be undone"))
        #expect(AskSystemCommand.shutdown.confirmationMessage.contains("Save your work"))
        #expect(AskSystemCommand.restart.confirmationMessage.contains("Save your work"))
        #expect(AskSystemCommand.resetSpotlight.confirmationMessage.contains("administrator password"))
    }

    @Test func `process dispatch uses fixed arguments and propagates failure`() async throws {
        let process = RecordingProcess()
        let runner = AskSystemCommandRunner(process: process)
        for command in AskSystemCommand.allCases where AskSystemCommandRunner.invocation(for: command) != nil {
            try await runner.run(command)
        }
        #expect(process.calls.count == 12)
        #expect(process.calls.contains(.init(executable: "/usr/bin/pmset", arguments: ["displaysleepnow"])))
        #expect(process.calls.contains(.init(executable: "/usr/bin/killall", arguments: ["Dock"])))
        process.exitCode = 1
        do {
            try await runner.run(.displaySleep)
            Issue.record("Nonzero exit must be reported")
        } catch let failure as AskPluginFailure {
            #expect(failure.message == "Denied" && !failure.retry)
        } catch {
            Issue.record(error)
        }
    }

    private final class RecordingProcess: ProcessCommandRunning {
        var calls: [AskSystemCommandRunner.Invocation] = []
        var exitCode: Int32 = 0
        func run(
            executablePath: String,
            arguments: [String],
            environment _: [String: String]?,
            currentDirectoryURL _: URL?
        ) async throws -> ProcessCommandResult {
            calls.append(.init(executable: executablePath, arguments: arguments))
            return .init(stdout: "", stderr: "Denied", exitCode: exitCode)
        }
    }
}
