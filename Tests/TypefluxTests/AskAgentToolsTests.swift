import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

/// Skills, memory notes, desktop helpers, browser v2 and their wiring in AskLocalTools.
@MainActor
final class AskAgentToolsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-agent-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func settings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "ask-agent-tools-\(UUID().uuidString)")!)
    }

    private func registry() -> MCPRegistry {
        MCPRegistry(settingsStore: MCPSettingsStore(defaults: UserDefaults(suiteName: "ask-agent-mcp-\(UUID().uuidString)")!))
    }

    private func call(_ name: String, _ arguments: [String: Any]) -> AskToolCall {
        let data = try! JSONSerialization.data(withJSONObject: arguments)
        return AskToolCall(id: UUID().uuidString, function: .init(name: name, arguments: String(decoding: data, as: UTF8.self)))
    }

    // MARK: - Skills

    func testSkillParsingOverridesAndLoading() throws {
        let parsed = try XCTUnwrap(AskSkillLibrary.parse("---\nname: Release Notes\ndescription: \"Write release notes\"\n---\n# Steps\nDo it.", fallbackName: "x"))
        XCTAssertEqual(parsed.name, "release-notes")
        XCTAssertEqual(parsed.description, "Write release notes")
        XCTAssertEqual(parsed.body, "# Steps\nDo it.")
        let plain = try XCTUnwrap(AskSkillLibrary.parse("# Title\nFirst real line\nmore", fallbackName: "My Skill"))
        XCTAssertEqual(plain.name, "my-skill")
        XCTAssertEqual(plain.description, "First real line")
        XCTAssertNil(AskSkillLibrary.parse("---\nname: x\n---\n", fallbackName: "x"))
        XCTAssertNil(AskSkillLibrary.parse("body", fallbackName: "名前"))

        let library = AskSkillLibrary(userDirectory: root)
        XCTAssertEqual(Set(library.skills().map(\.name)), Set(AskBuiltinSkills.all.map(\.name)))
        let custom = root.appendingPathComponent("email-reply")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try "---\ndescription: Our house style\n---\nAlways sign as Team.".write(to: custom.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "print(1)".write(to: custom.appendingPathComponent("helper.py"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("broken"), withIntermediateDirectories: true)

        let skills = library.skills()
        let replaced = try XCTUnwrap(skills.first { $0.name == "email-reply" })
        XCTAssertEqual(replaced.description, "Our house style")
        XCTAssertNotNil(replaced.directory)
        let loaded = try library.load("email-reply")
        XCTAssertTrue(loaded.contains("Always sign as Team."))
        XCTAssertTrue(loaded.contains("- helper.py"))
        XCTAssertTrue(try library.load("meeting-notes").contains("Action items"))
        XCTAssertThrowsError(try library.load("missing"))

        let definition = try XCTUnwrap(library.definition(skills))
        XCTAssertEqual(definition.name, "skill")
        XCTAssertTrue(definition.description.contains("- email-reply: Our house style"))
        XCTAssertNil(library.definition([]))
    }

    // MARK: - Memory notes

    func testMemoryNotesPersistAndFeedTheMemory() throws {
        let file = root.appendingPathComponent("notes.json")
        let store = AskMemoryNoteStore(fileURL: file)
        let first = try store.add("  Prefers metric units ", owner: "a")
        XCTAssertEqual(first.text, "Prefers metric units")
        XCTAssertEqual(try store.add("prefers METRIC units", owner: "a").id, first.id)
        try store.add("Lives in Berlin", owner: "a")
        try store.add("Other account", owner: "b")
        XCTAssertThrowsError(try store.add("   ", owner: "a"))
        XCTAssertThrowsError(try store.add(String(repeating: "x", count: 301), owner: "a"))

        let reloaded = AskMemoryNoteStore(fileURL: file)
        XCTAssertEqual(reloaded.list(owner: "a").map(\.text), ["Prefers metric units", "Lives in Berlin"])
        XCTAssertEqual(reloaded.list(owner: "b").count, 1)
        XCTAssertEqual(AskMemoryNoteStore.memoryText(reloaded.list(owner: "a"), limit: 1000), "Saved notes:\n- Lives in Berlin\n- Prefers metric units")
        XCTAssertEqual(AskMemoryNoteStore.memoryText(reloaded.list(owner: "a"), limit: 35), "Saved notes:\n- Lives in Berlin")
        XCTAssertNil(AskMemoryNoteStore.memoryText([], limit: 1000))
        XCTAssertNil(AskMemoryNoteStore.memoryText(reloaded.list(owner: "a"), limit: 10))

        XCTAssertTrue(try store.execute(["action": "list"], owner: "a").contains("\(first.id): Prefers metric units"))
        XCTAssertTrue(try store.execute(["action": "remember", "text": "Uses vim"], owner: "a").hasPrefix("Saved note"))
        XCTAssertEqual(try store.execute(["action": "forget", "id": first.id], owner: "a"), "Forgot note \(first.id).")
        XCTAssertThrowsError(try store.execute(["action": "forget", "id": "nope"], owner: "a"))
        XCTAssertThrowsError(try store.execute(["action": "explode"], owner: "a"))
        XCTAssertEqual(try store.execute(["action": "list"], owner: "nobody"), "No saved notes.")
        try store.clear(owner: "a")
        XCTAssertTrue(store.list(owner: "a").isEmpty)
        for index in 0 ..< AskMemoryNoteStore.maximumNotes { try store.add("note \(index)", owner: "full") }
        XCTAssertThrowsError(try store.add("one more", owner: "full"))

        // Saved notes join the global memory after the soul summary.
        let settings = settings()
        settings.globalSoulMemoryEnabled = false
        let notes = AskMemoryNoteStore(fileURL: root.appendingPathComponent("provider.json"))
        try notes.add("Prefers short answers", owner: "owner")
        let provider = AskMemoryProvider(settings: settings, soulStore: GlobalSoulMemoryStore(fileURL: root.appendingPathComponent("soul.json")),
                                         recentStore: RecentInputMemoryStore(fileURL: root.appendingPathComponent("recent.json")),
                                         noteStore: notes, ownerID: { "owner" })
        XCTAssertEqual(provider.memory(bundleIdentifier: nil, appName: nil)?.global, "Saved notes:\n- Prefers short answers")
    }

    // MARK: - Desktop helpers

    func testHotkeysKeysAndPoints() throws {
        let copy = try XCTUnwrap(AskDesktopActions.parseHotkey("Cmd+C"))
        XCTAssertEqual(copy.key, 8)
        XCTAssertEqual(copy.flags, .maskCommand)
        let tab = try XCTUnwrap(AskDesktopActions.parseHotkey("cmd + shift + t"))
        XCTAssertEqual(tab.flags, [.maskCommand, .maskShift])
        XCTAssertEqual(AskDesktopActions.parseHotkey("ctrl+option+5")?.key, 23)
        XCTAssertNil(AskDesktopActions.parseHotkey("hyper+c"))
        XCTAssertNil(AskDesktopActions.parseHotkey("cmd+"))
        XCTAssertNil(AskDesktopActions.parseHotkey("cmd+unknownkey"))
        XCTAssertEqual(AskDesktopActions.keyCodes["pagedown"], 121)
        XCTAssertEqual(AskDesktopActions.keyCodes["/"], 44)

        let bounds = CGRect(x: 100, y: 50, width: 1001, height: 501)
        XCTAssertEqual(AskDesktopActions.point(x: 0.5, y: 1, in: bounds), CGPoint(x: 600, y: 550))
        XCTAssertNil(AskDesktopActions.point(x: 1.2, y: 0, in: bounds))
        XCTAssertNil(AskDesktopActions.point(x: .nan, y: 0, in: bounds))
    }

    func testAccessibilityTreeDescription() {
        typealias Node = AskDesktopActions.Node
        let display = CGRect(x: 0, y: 0, width: 1001, height: 1001)
        let tree = Node(role: "AXWindow", name: "Editor", value: "", frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), children: [
            Node(role: "AXGroup", name: "", value: "", frame: nil, children: [
                Node(role: "AXButton", name: "Save", value: "", frame: CGRect(x: 90, y: 190, width: 20, height: 20)),
                Node(role: "AXTextField", name: "Title", value: "Draft\nv2", frame: CGRect(x: 2000, y: 0, width: 10, height: 10))
            ])
        ])
        let text = AskDesktopActions.describe(tree, display: display)
        XCTAssertEqual(text, """
        Window "Editor" @(0.500, 0.500)
          Button "Save" @(0.100, 0.200)
          TextField "Title = Draft v2"
        """)
        let wide = Node(role: "AXList", name: "", value: "", frame: nil,
                        children: (0 ..< 400).map { Node(role: "AXStaticText", name: "Row \($0)", value: "", frame: nil) })
        let limited = AskDesktopActions.describe(wide, display: display)
        XCTAssertTrue(limited.hasSuffix("[more elements omitted]"))
        XCTAssertNil(AskDesktopActions.snapshot(pid: -1))
    }

    // MARK: - Browser

    func testBrowserScriptsForSnapshotRefsAndNavigation() throws {
        let snapshot = AskBrowserExecutor.observationScript(id: "version", read: false)
        XCTAssertTrue(snapshot.contains("observationID"))
        let byRef = try AskBrowserExecutor.command(["action": "click", "ref": "version:7"])
        XCTAssertTrue(byRef.contains("version:7"))
        for action in ["fill", "back", "scroll"] {
            let args: [String: Any] = ["action": action, "ref": "version:2", "text": "hi", "amount": -2]
            let command = try AskBrowserExecutor.command(args)
            XCTAssertTrue(command.contains(action))
        }
        for invalid: [String: Any] in [["action": "click", "ref": 0], ["action": "scroll"],
                                        ["action": "scroll", "amount": 20], ["action": "fill", "ref": 1]] {
            XCTAssertThrowsError(try AskBrowserExecutor.command(invalid))
        }
    }

    func testBrowserFallsBackToARunningBrowserAndRisksAreTiered() async throws {
        let tools = AskLocalTools(registry: registry(), settings: settings(), skills: AskSkillLibrary(userDirectory: root),
                                  notes: AskMemoryNoteStore(fileURL: root.appendingPathComponent("n.json")), owner: { "o" })
        tools.runningBundleIdentifiers = { [] }
        XCTAssertNil(tools.browserBundle(conversationId: nil))
        var names = await tools.definitions(conversationId: nil).map(\.name)
        XCTAssertFalse(names.contains("browser"))
        tools.runningBundleIdentifiers = { ["com.google.Chrome", "com.apple.Safari"] }
        XCTAssertEqual(tools.browserBundle(conversationId: "unbound"), "com.apple.Safari")
        names = await tools.definitions(conversationId: nil).map(\.name)
        XCTAssertEqual(Array(names.prefix(2)), ["computer", "browser"])
        XCTAssertTrue(names.contains("skill") && names.contains("memory"))
        // No authorized folders: no files tool. Code execution follows its setting and this Mac.
        XCTAssertFalse(names.contains("files"))
        XCTAssertEqual(names.contains("run_code"), tools.sandbox.definition() != nil)

        let risks: [(String, [String: Any], AskToolRisk)] = [
            ("skill", ["name": "x"], .none), ("computer", ["action": "inspect"], .read), ("computer", ["action": "wait"], .read),
            ("computer", ["action": "drag"], .write), ("browser", ["action": "snapshot"], .read), ("browser", ["action": "back"], .write),
            ("files", ["action": "read", "path": "a"], .read), ("files", ["action": "write", "path": "a"], .write),
            ("run_code", ["language": "python", "code": "1"], .write), ("memory", ["action": "list"], .read),
            ("memory", ["action": "remember"], .write), ("unknown", [:], .destructive)
        ]
        for (name, args, risk) in risks {
            XCTAssertEqual(tools.risk(of: call(name, args)), risk, "\(name) \(args)")
        }
        XCTAssertEqual(AskLocalTools.builtinRisk(AskToolCall(id: "x", function: .init(name: "files", arguments: "not json"))), .write)
    }

    func testLocalToolsExecuteFilesCodeSkillsAndMemory() async throws {
        let settings = settings()
        let folder = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "data".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        settings.askFileAccessFolders = [folder.path, folder.path, ""]
        XCTAssertEqual(settings.askFileAccessFolders, [folder.path])
        XCTAssertTrue(settings.askCodeExecutionEnabled)
        let notes = AskMemoryNoteStore(fileURL: root.appendingPathComponent("n.json"))
        let sandbox = AskCodeSandbox(baseDirectory: root.appendingPathComponent("sandbox"), allowProcessGroupExecution: true)
        let tools = AskLocalTools(registry: registry(), settings: settings, sandbox: sandbox,
                                  skills: AskSkillLibrary(userDirectory: root.appendingPathComponent("skills")), notes: notes, owner: { "me" })
        tools.runningBundleIdentifiers = { [] }
        let names = await tools.definitions(conversationId: "c").map(\.name)
        XCTAssertTrue(names.contains("files"))
        XCTAssertEqual(names.contains("run_code"), sandbox.definition() != nil)

        let read = try await tools.execute(call("files", ["action": "read", "path": "a.txt"]), conversationId: "c")
        XCTAssertTrue(read.content.contains("1\tdata"))
        let skill = try await tools.execute(call("skill", ["name": "data-analysis"]), conversationId: "c")
        XCTAssertTrue(skill.content.hasPrefix("# Skill: data-analysis"))
        _ = try await tools.execute(call("memory", ["action": "remember", "text": "Likes tea"]), conversationId: "c")
        XCTAssertEqual(notes.list(owner: "me").map(\.text), ["Likes tea"])
        if sandbox.isSupported {
            let failed = try await tools.execute(call("run_code", ["language": "shell", "code": "echo hi; exit 2"]), conversationId: "c")
            XCTAssertTrue(failed.isError)
            XCTAssertTrue(failed.content.contains("Exit code: 2"))
        }
        settings.askCodeExecutionEnabled = false
        do {
            _ = try await tools.execute(call("run_code", ["language": "shell", "code": "echo hi"]), conversationId: "c")
            XCTFail("Code execution is disabled")
        } catch {}
        for bad in [call("skill", [:]), call("files", ["action": "read", "path": "/etc/hosts"]), call("nope", ["action": "x"])] {
            do {
                _ = try await tools.execute(bad, conversationId: "c")
                XCTFail("Expected failure for \(bad.function.name)")
            } catch {}
        }
        XCTAssertNotNil(tools.fileTools.resolvedRoots.first)
    }

    func testComputerAndBrowserDispatchWithoutTouchingTheDesktop() async throws {
        let runner = ObservationScriptRunner()
        let tools = AskLocalTools(registry: registry(), runner: runner, settings: settings(), skills: AskSkillLibrary(userDirectory: root),
                                  notes: AskMemoryNoteStore(fileURL: root.appendingPathComponent("n.json")), owner: { "o" })
        tools.runningBundleIdentifiers = { ["com.apple.Safari"] }
        let waited = try await tools.execute(call("computer", ["action": "wait", "seconds": 0]), conversationId: "c")
        XCTAssertEqual(waited.content, "Waited 0.0 s.")
        // No bound target: actions fail before any event is posted.
        for action in ["inspect", "click", "hotkey", "nonsense"] {
            do {
                _ = try await tools.execute(call("computer", ["action": action, "x": 0.5, "y": 0.5, "keys": "cmd+c"]), conversationId: "c")
                XCTFail("\(action) must fail without a target")
            } catch {}
        }
        tools.browserExecutor.processInstance = { _ in "42:1" }
        let page = try await tools.execute(call("browser", ["action": "snapshot"]), conversationId: "c")
        XCTAssertEqual(page.observation?.browserId, "com.apple.Safari")
        XCTAssertEqual(page.outcome?.eventDispatched, false)
        XCTAssertTrue(runner.scripts.first?.contains("com.apple.Safari") == true)
        tools.runningBundleIdentifiers = { [] }
        do {
            _ = try await tools.execute(call("browser", ["action": "read"]), conversationId: "c")
            XCTFail("No browser is running")
        } catch {}
    }

    func testRegistryBuildsRealClientsForConfiguredTransports() async {
        let registry = registry()
        let stdio = MCPServerConfig(name: "Missing", transport: .stdio(MCPStdioTransportConfig(command: "typeflux-missing-\(UUID().uuidString)")))
        let http = MCPServerConfig(name: "Offline", transport: .http(MCPHTTPTransportConfig(url: "http://127.0.0.1:1/mcp")))
        for config in [stdio, http] {
            do {
                try await registry.addServer(config)
                XCTFail("\(config.name) should not connect")
            } catch {}
        }
        let count = await registry.connectedServerCount
        XCTAssertEqual(count, 0)
    }

    func testSettingsViewListsAndRemovesNotes() throws {
        let settings = settings()
        settings.askFileAccessFolders = [root.path]
        let notes = AskMemoryNoteStore(fileURL: root.appendingPathComponent("view-notes.json"))
        let note = try notes.add("Prefers dark mode", owner: "o")
        let view = AskToolsSettingsView(settings: settings, skills: AskSkillLibrary(userDirectory: root), notes: notes, owner: { "o" },
                                        tab: .memory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        // ARC owns the window; closing must not release it a second time.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        view.removeNote(note)
        XCTAssertTrue(notes.list(owner: "o").isEmpty)
        window.close()
    }

    // MARK: - Presentation

    func testToolTitlesPlanAndRunDecoding() throws {
        XCTAssertEqual(AskTheme.toolTitle(call("skill", ["name": "email-reply"])), L("ask.tool.skill") + " · email-reply")
        XCTAssertEqual(AskTheme.toolTitle(call("run_code", ["language": "python", "code": "1"])), L("ask.tool.run_code") + " · python")
        XCTAssertEqual(AskTheme.toolTitle(call("files", ["action": "edit"])), L("ask.files.action.edit"))
        XCTAssertEqual(AskTheme.toolTitle(call("files", ["action": "read", "path": "~/Documents/release.md"])),
                       L("ask.files.action.read") + " · release.md")
        XCTAssertEqual(AskTheme.toolTitle(call("memory", [:])), L("ask.tool.memory"))
        XCTAssertEqual(AskTheme.toolTitle(call("computer", ["action": "hotkey"])), L("ask.tool.computer") + " · " + L("ask.action.hotkey"))
        XCTAssertEqual(AskPresentation.toolSymbol(call("run_code", [:])), "terminal")
        XCTAssertEqual(AskPresentation.toolSymbol(call("research", [:])), "doc.text.magnifyingglass")

        let json = #"{"id":"r","device_id":"d","status":"running","steps":1,"updated_at":"2026-10-01T00:00:00Z","tools":[],"pending":[],"plan":[{"step":"Search","status":"completed"},{"step":"Write","status":"in_progress"}]}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(AskRun.self, from: Data(json.utf8))
        XCTAssertEqual(run.plan?.count, 2)
        XCTAssertEqual(AskPlanList.symbol("completed"), "checkmark.circle.fill")
        XCTAssertEqual(AskPlanList.symbol("in_progress"), "circle.dotted.circle")
        XCTAssertEqual(AskPlanList.symbol("pending"), "circle")
        let hosting = NSHostingView(rootView: AskPlanList(items: run.plan ?? []).frame(width: 400))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.height, 20)

        let settings = settings()
        settings.askFileAccessFolders = ["/a", "/b"]
        let view = AskToolsSettingsView(settings: settings, skills: AskSkillLibrary(userDirectory: root),
                                        notes: AskMemoryNoteStore(fileURL: root.appendingPathComponent("s.json")), owner: { "o" })
        view.removeFolder("/a")
        XCTAssertEqual(settings.askFileAccessFolders, ["/b"])
        for tab in [AgentConfigurationTab.general, .tools, .skills, .memory] {
            var tabView = view
            tabView.tab = tab
            let settingsHost = NSHostingView(rootView: tabView.frame(width: 600))
            settingsHost.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(settingsHost.fittingSize.height, 60, "\(tab)")
        }
        XCTAssertEqual(AgentConfigurationTab.tools.title, L("agent.section.tools"))
        XCTAssertEqual(AskToolsSettingsView.searchProviderName(.none), L("ask.settings.search.none"))
        XCTAssertEqual(AskToolsSettingsView.searchProviderName(.tavily), "Tavily")
        XCTAssertEqual(AskToolsSettingsView.searchProviderName(.brave), "Brave Search")
    }

    func testNewStringsExistInEveryLanguage() throws {
        for language in AppLanguage.allCases {
            let bundle = try XCTUnwrap(language.bundleLocalizationCandidates.lazy
                .compactMap { Bundle.appResources.path(forResource: $0, ofType: "lproj") }.first.flatMap(Bundle.init(path:)))
            for key in ["ask.files.denied", "ask.code.unavailable", "ask.settings.folders.title", "ask.tool.update_plan", "ask.action.inspect", "agent.section.tools",
                        "agent.section.skills", "agent.section.memory", "ask.settings.skills.install", "ask.skills.install.notFound",
                        "agent.settings.runMode", "agent.settings.web", "agent.settings.code", "agent.settings.mcp"] {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: nil, table: nil), key, "\(key) in \(language.rawValue)")
            }
            XCTAssertEqual(bundle.localizedString(forKey: "ask.activity.plan", value: nil, table: nil).components(separatedBy: "%d").count - 1, 2)
            XCTAssertEqual(bundle.localizedString(forKey: "ask.files.editAmbiguous", value: nil, table: nil).components(separatedBy: "%d").count - 1, 1)
        }
    }
}
