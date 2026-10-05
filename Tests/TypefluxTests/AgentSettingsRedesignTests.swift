import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

/// The redesigned Agent settings page: view helpers, MCP actions and rendering of every tab.
@MainActor
final class AgentSettingsRedesignTests: XCTestCase {
    private var root: URL!
    private var suite: String!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-settings-\(UUID().uuidString)")
        suite = "agent-settings-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func settings() throws -> SettingsStore {
        SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    func testSkillFilteringAndInstallPreview() {
        let skills = [AskSkill(name: "email-reply", description: "Reply to mail", body: ""),
                      AskSkill(name: "data-analysis", description: "Analyse tables", body: "")]
        let filter = AskToolsSettingsView.filteredSkills
        XCTAssertEqual(filter(skills, [], "", .all).map(\.name), ["email-reply", "data-analysis"])
        XCTAssertEqual(filter(skills, [], "MAIL", .all).map(\.name), ["email-reply"])
        XCTAssertEqual(filter(skills, [], "tables", .all).map(\.name), ["data-analysis"])
        XCTAssertEqual(filter(skills, ["email-reply"], "", .enabled).map(\.name), ["data-analysis"])
        XCTAssertEqual(filter(skills, ["email-reply"], " ", .disabled).map(\.name), ["email-reply"])

        XCTAssertNil(AskToolsSettingsView.installPreview("  "))
        let invalid = AskToolsSettingsView.installPreview("https://example.com/a/b")
        XCTAssertEqual(invalid?.valid, false)
        let folder = AskToolsSettingsView.installPreview("https://github.com/acme/skills/tree/main/skills/pdf")
        XCTAssertEqual(folder?.valid, true)
        XCTAssertEqual(folder?.text, L("agent.skills.install.preview", "acme/skills", "main", "skills/pdf"))
        let repository = AskToolsSettingsView.installPreview("github.com/acme/skills")
        XCTAssertEqual(repository?.text, L("agent.skills.install.preview", "acme/skills",
                                           L("agent.skills.install.defaultBranch"), L("agent.skills.install.root")))
    }

    func testSkillActionsOnALocalSkill() async throws {
        let settings = try settings()
        let library = AskSkillLibrary(userDirectory: root.appendingPathComponent("Skills"))
        let folder = library.userDirectory.appendingPathComponent("house-style")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\ndescription: Our house style\n---\nSign as Team.".write(
            to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let view = AskToolsSettingsView(settings: settings, skills: library,
                                        notes: AskMemoryNoteStore(fileURL: root.appendingPathComponent("n.json")),
                                        owner: { "o" }, tab: .extensions,
                                        permissions: .fixed(accessibility: false, screenRecording: false))
        let local = try XCTUnwrap(library.skills().first { $0.name == "house-style" })
        let builtin = try XCTUnwrap(library.skills().first { $0.directory == nil })
        XCTAssertEqual(view.skillBadge(local).text, L("ask.settings.skills.local"))
        XCTAssertEqual(view.skillBadge(builtin).text, L("ask.settings.skills.builtin"))
        XCTAssertFalse(view.skillBadge(builtin).accent)

        _ = NSApplication.shared
        let sheet = try await render(view.installSheet, appearance: .aqua, height: 400)
        XCTAssertGreaterThan(sheet.count, 4000)
        view.startInstall()  // An empty link never starts an install.

        view.rollbackSkill(local)  // No previous version: reported, not thrown.
        XCTAssertNotNil(library.skills().first { $0.name == "house-style" })
        view.setSkill("house-style", enabled: false)
        view.removeSkill(local)
        XCTAssertNil(library.skills().first { $0.name == "house-style" })
        XCTAssertFalse(settings.askDisabledSkills.contains("house-style"), "Removal resets the preference")
        view.removeSkill(local)  // Already gone: reported, not thrown.
    }

    func testFolderRemovalCanBeRestored() throws {
        let removed = AskToolsSettingsView.RemovedFolder(path: "/b", index: 1)
        XCTAssertEqual(AskToolsSettingsView.restoring(removed, in: ["/a", "/c"]), ["/a", "/b", "/c"])
        XCTAssertEqual(AskToolsSettingsView.restoring(removed, in: []), ["/b"])
        XCTAssertEqual(AskToolsSettingsView.restoring(removed, in: ["/b", "/a"]), ["/b", "/a"], "Already back")

        let settings = try settings()
        settings.askFileAccessFolders = ["/a", "/b"]
        let view = AskToolsSettingsView(settings: settings, skills: AskSkillLibrary(userDirectory: root),
                                        notes: AskMemoryNoteStore(fileURL: root.appendingPathComponent("n.json")),
                                        owner: { "o" }, permissions: .fixed(accessibility: true, screenRecording: true))
        view.removeFolder("/a")
        view.setCodeExecution(false)
        XCTAssertEqual(settings.askFileAccessFolders, ["/b"])
        XCTAssertFalse(settings.askCodeExecutionEnabled)
    }

    func testSearchConnectionTestReportsOutcome() async {
        let config = AskSearchConfiguration(provider: .brave, apiKey: "key")
        let success = AskCloudflareConnectionTest { _ in }
        XCTAssertNil(success.succeeded)
        success.start(config)
        for _ in 0 ..< 100 where success.testing { await Task.yield() }
        XCTAssertEqual(success.succeeded, true)
        success.reset()
        XCTAssertNil(success.succeeded)
        let failure = AskCloudflareConnectionTest { _ in throw AskLocalError.message("nope") }
        failure.start(config)
        for _ in 0 ..< 100 where failure.testing { await Task.yield() }
        XCTAssertEqual(failure.succeeded, false)
        failure.start(.init(provider: .brave))
        XCTAssertEqual(failure.succeeded, false, "An incomplete configuration fails without searching")
    }

    func testMCPImportDuplicateAndRemoval() throws {
        let settings = try settings()
        let viewModel = StudioViewModel(settingsStore: settings, historyStore: SQLiteHistoryStore(baseDir: root.appendingPathComponent("history")),
                                        initialSection: .agent)
        viewModel.importMCPServers([])
        XCTAssertTrue(viewModel.mcpServers.isEmpty)
        let imported = try MCPServerImport.parse(#"{"mcpServers": {"notion": {"command": "npx"}}}"#)
        viewModel.importMCPServers(imported.servers)
        XCTAssertEqual(settings.mcpServers.map(\.name), ["notion"])

        let source = try XCTUnwrap(viewModel.mcpServers.first)
        let copy = try XCTUnwrap(viewModel.duplicateMCPServer(id: source.id))
        XCTAssertEqual(copy.name, L("agent.mcp.copyName", "notion"))
        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertNotNil(viewModel.duplicateMCPServer(id: source.id), "A second copy gets a free name")
        XCTAssertEqual(Set(settings.mcpServers.map(\.name)).count, 3)
        XCTAssertNil(viewModel.duplicateMCPServer(id: UUID()))

        viewModel.removeMCPServer(id: copy.id)
        XCTAssertNil(viewModel.mcpServerTestResults[copy.id])
        XCTAssertEqual(settings.mcpServers.count, 2)
    }

    func testMCPConnectionResultIsRecordedPerServer() async throws {
        let settings = try settings()
        let viewModel = StudioViewModel(settingsStore: settings, historyStore: SQLiteHistoryStore(baseDir: root.appendingPathComponent("history")),
                                        initialSection: .agent)
        viewModel.importMCPServers([MCPServerConfig(name: "bad", transport: .http(.init(url: "")))])
        let server = try XCTUnwrap(viewModel.mcpServers.first)
        viewModel.testMCPConnection(for: server)
        XCTAssertEqual(viewModel.mcpServerTestResults[server.id], MCPConnectionTestState.testing)
        for _ in 0 ..< 200 where viewModel.mcpServerTestResults[server.id] == MCPConnectionTestState.testing {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .failure? = viewModel.mcpServerTestResults[server.id] else {
            return XCTFail("Expected a failed test, got \(String(describing: viewModel.mcpServerTestResults[server.id]))")
        }
        viewModel.beginEditMCPServer(server)
        viewModel.mcpDraftHTTPURL = "https://example.invalid/mcp"
        viewModel.saveMCPDraft()
        XCTAssertNil(viewModel.mcpServerTestResults[server.id], "Editing clears the stale result")
    }

    func testEveryTabRendersInBothAppearances() async throws {
        let settings = try settings()
        settings.askFileAccessFolders = ["/Users/me/Documents"]
        settings.askNewConversationsStayLocal = true
        settings.mcpServers = [MCPServerConfig(name: "notion", transport: .stdio(.init(command: "npx")))]
        let notes = AskMemoryNoteStore(fileURL: root.appendingPathComponent("notes.json"))
        try notes.add("Prefers concise answers", owner: "o")
        let library = AskSkillLibrary(userDirectory: root.appendingPathComponent("Skills"))
        _ = NSApplication.shared
        for tab in AgentConfigurationTab.allCases {
            var reported: [AgentCapabilityStatus] = []
            for granted in [false, true] {
                let view = AskToolsSettingsView(settings: settings, skills: library, notes: notes, owner: { "o" }, tab: tab,
                                                onStatusesChange: { reported = $0 },
                                                permissions: .fixed(accessibility: granted, screenRecording: granted))
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let png = try await render(view, appearance: appearance)
                    XCTAssertGreaterThan(png.count, 4000, "\(tab)")
                    if let output = ProcessInfo.processInfo.environment["TYPEFLUX_AGENT_SETTINGS_SNAPSHOTS"], granted {
                        let directory = URL(fileURLWithPath: output)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try png.write(to: directory.appendingPathComponent(
                            "agent-\(tab.rawValue)-\(appearance == .aqua ? "light" : "dark").png"))
                    }
                }
            }
            XCTAssertEqual(reported.count, AgentCapability.allCases.count, "\(tab) reports capability states")
            XCTAssertEqual(reported.first { $0.capability == .webSearch }?.level, .attention,
                           "Private conversations without search need attention")
        }
    }

    func testComponentsRender() async throws {
        let view = VStack(alignment: .leading, spacing: 12) {
            AgentUnderlineTabs(options: [(label: "A", value: 1, needsAttention: true), (label: "B", value: 2, needsAttention: false)],
                               selection: .constant(1))
            AgentStatusBadge(level: .ready, label: "Ready")
            AgentStatusBadge(level: .attention, label: "Fix")
            AgentStatusBadge(level: .off, label: "Off")
            AgentFlowLayout { ForEach(0 ..< 12) { AgentFactChip(text: "Rule \($0)", systemImage: $0 == 0 ? "lock" : nil) } }
                .frame(width: 300)
            AgentSearchBox(placeholder: "Search", text: .constant("query"))
            AgentEmptyState(symbol: "server.rack", title: "Empty", message: "Nothing yet") { Button("Add") {} }
            AgentUndoBanner(message: "Removed", onUndo: {}, onDismiss: {})
            AgentFormRow(label: "Token", required: true) { TextField("", text: .constant("")) }
            AgentDisclosureButton(title: "Advanced", expanded: .constant(true))
            MCPKeyValueEditor(text: .constant("API_KEY=1\nNODE_ENV=production"), keyPlaceholder: "NAME", valuePlaceholder: "Value")
            AgentSearchForm(provider: .constant(.cloudflare), apiKey: .constant(""), cloudflare: .constant(.init()),
                            missing: [.apiKey, .accountID], configuration: .init(provider: .cloudflare))
            AgentSearchForm(provider: .constant(.tavily), apiKey: .constant("k"), cloudflare: .constant(.init()),
                            missing: [], configuration: .init(provider: .tavily, apiKey: "k"))
            AgentSkillDetailView(
                skill: AskSkill(name: "release-review", description: "Review a release", body: "",
                                directory: root),
                badge: (text: "GitHub", accent: true),
                source: AskSkillSource(url: "https://github.com/a/b", repository: "a/b", ref: "main", path: "skills/x",
                                       installedAt: Date(), commit: String(repeating: "a", count: 40),
                                       installationID: UUID(), version: "1", resources: [], declaredPermissions: ["files.read"]),
                enabled: .constant(true), canRollback: true, onRollback: {}, onReveal: {}, onRemove: {}, onClose: {}
            )
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let png = try await render(view, appearance: appearance, height: 1600)
            XCTAssertGreaterThan(png.count, 4000)
        }
        XCTAssertEqual(AgentSearchForm.keyURL(for: .tavily)?.host, "app.tavily.com")
        XCTAssertNotNil(AgentSearchForm.keyURL(for: .brave))
        XCTAssertNil(AgentSearchForm.keyURL(for: .cloudflare))
        XCTAssertEqual(AskCloudflareSearchSettingsView.engineName("exa"), "Exa")
        XCTAssertEqual(AskCloudflareSearchSettingsView.engineName("linkup"), "Linkup")
        XCTAssertEqual(AskCloudflareSearchSettingsView.engineName("ceramic"), "Ceramic.ai")
    }

    func testOverviewSummaryDescribesAttention() {
        let ready = AgentCapabilityStatus(capability: .files, level: .ready, label: "")
        let fix = AgentCapabilityStatus(capability: .webSearch, level: .attention, label: "")
        XCTAssertEqual(AgentOverviewSummary(statuses: [ready], noteCount: 0, onFix: { _ in }).detail,
                       L("agent.overview.allSet"))
        XCTAssertEqual(AgentOverviewSummary(statuses: [ready, fix], noteCount: 2, onFix: { _ in }).detail,
                       L("agent.overview.needsAttention", 1, AgentCapability.webSearch.title) + " · " + L("agent.overview.notes", 2))
    }

    func testAgentStringsExistInEveryLanguage() throws {
        var tables: [AppLanguage: [String: String]] = [:]
        for language in AppLanguage.allCases {
            let path = try XCTUnwrap(language.bundleLocalizationCandidates.compactMap {
                Bundle.module.path(forResource: $0, ofType: "lproj")
            }.first)
            let url = URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings")
            tables[language] = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        }
        let english = try XCTUnwrap(tables[.english])
        let keys = english.keys.filter { $0.hasPrefix("agent.") } + ["common.done"]
        XCTAssertGreaterThan(keys.count, 100)
        for (language, table) in tables {
            for key in keys {
                let value = try XCTUnwrap(table[key], "\(key) is missing in \(language.rawValue)")
                XCTAssertFalse(value.isEmpty, key)
                // Every translation must take the same format arguments as English.
                for specifier in ["%d", "%@", "%1$d", "%2$d", "%1$@", "%2$@", "%3$@"] {
                    XCTAssertEqual(value.components(separatedBy: specifier).count,
                                   english[key]!.components(separatedBy: specifier).count,
                                   "\(key) \(specifier) in \(language.rawValue)")
                }
            }
        }
    }

    private func render(_ view: some View, appearance: NSAppearance.Name, height: CGFloat = 1100) async throws -> Data {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view.padding(24).frame(width: 860, height: height, alignment: .top)
            .background(StudioTheme.surface))
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
