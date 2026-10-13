import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

@MainActor
final class SettingsPolishTests: XCTestCase {
    private var suite: String!
    private var root: URL!
    private var settings: SettingsStore!
    private var previousLanguage: AppLanguage!
    private var previousLogin = false

    override func setUp() {
        TypefluxTestApplicationEnvironment.prepare()
        previousLanguage = AppLocalization.shared.language
        previousLogin = AuthState.shared.isLoggedIn
        AuthState.shared.isLoggedIn = false
        AppLocalization.shared.setLanguage(.english)
        suite = "settings-polish-" + UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        settings.appLanguage = .english
    }

    override func tearDown() {
        settings.defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
        AppLocalization.shared.setLanguage(previousLanguage)
        AuthState.shared.isLoggedIn = previousLogin
    }

    private func viewModel() -> StudioViewModel {
        StudioViewModel(
            settingsStore: settings,
            historyStore: SQLiteHistoryStore(baseDir: root),
            initialSection: .agent,
            modelLibrary: AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
        )
    }

    func testFieldsMenusAndActionsUseNativeSizing() {
        let field = height(TextField("Name", text: .constant("long example name"))
            .textFieldStyle(.roundedBorder))
        XCTAssertGreaterThan(field, 0)
        XCTAssertEqual(
            height(SecureField("Key", text: .constant("fixture")).textFieldStyle(.roundedBorder)),
            field,
            accuracy: 0.5
        )
        XCTAssertEqual(
            height(TypefluxPopup(title: "Protocol",
                                 options: [(label: "Responses", value: 1)],
                                 selection: .constant(1))),
            height(TypefluxPopup("Protocol", selection: .constant(1), borderless: true) { Text("Responses").tag(1) }),
            accuracy: 0.5
        )
        XCTAssertGreaterThan(height(Button("Save") {}.buttonStyle(.borderedProminent)), 0)
        let plainCard = height(StudioTextInputCard(label: "Name", placeholder: "Name", text: .constant("value")))
        XCTAssertEqual(
            height(StudioTextInputCard(label: "Key", placeholder: "Key", text: .constant("value"), secure: true)),
            plainCard,
            accuracy: 0.5
        )
        XCTAssertGreaterThanOrEqual(
            height(StudioSuggestedTextInputCard(
                label: "Model",
                placeholder: "Model",
                text: .constant("manual-model"),
                suggestions: ["suggested-model"]
            )),
            field
        )
    }

    func testClosingOrEditingMCPDraftCancelsItsTestAndClearsStaleResults() async {
        let model = viewModel()
        model.beginAddMCPServer()
        model.mcpDraftTransportType = .http
        model.mcpDraftHTTPURL = ""
        model.testMCPDraftConnection()
        XCTAssertEqual(model.mcpConnectionTestState, .testing)
        model.resetMCPDraftConnectionTest()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertEqual(model.mcpConnectionTestState, .idle)
        model.mcpConnectionTestState = .failure(message: "Old endpoint")
        model.resetMCPDraftConnectionTest()
        XCTAssertEqual(model.mcpConnectionTestState, .idle)
    }

    func testClosingDraftDoesNotClearSavedServerConnectionResult() async {
        let model = viewModel()
        let server = MCPServerConfig(name: "Invalid fixture", transport: .http(.init(url: "")))
        model.importMCPServers([server])
        model.testMCPConnection(for: server)
        model.beginAddMCPServer()
        model.resetMCPDraftConnectionTest()
        XCTAssertEqual(model.mcpServerTestResults[server.id], .testing)
        for _ in 0 ..< 100 where model.mcpServerTestResults[server.id] == .testing {
            await Task.yield()
        }
        guard case .failure? = model.mcpServerTestResults[server.id]
        else { return XCTFail("Expected fixture validation failure") }
        XCTAssertEqual(model.mcpConnectionTestState, .idle)
    }

    func testAgentPageOpensMCPFormAndCancelClearsItsLoadingState() async throws {
        let model = viewModel()
        try await withWindow(StudioView(viewModel: model), width: 1100, height: 800) { window, hosting in
            try await self.selectPane(.mcpServers, in: hosting)
            try await SettingsBehaviorTestSupport.wait("MCP add action after native pane selection") {
                self.elements(in: hosting).contains { $0.accessibilityLabel() == L("agent.mcp.addServer") }
            }
            let add = try XCTUnwrap(self.elements(in: hosting)
                .first { $0.accessibilityLabel() == L("agent.mcp.addServer") })
            try self.click(add, in: window)
            try await SettingsBehaviorTestSupport.wait("MCP editor sheet") { window.attachedSheet?.contentView != nil }
            let sheet = try XCTUnwrap(window.attachedSheet)
            let content = try XCTUnwrap(sheet.contentView)
            let save = try XCTUnwrap(self.elements(in: content).first { $0.accessibilityLabel() == L("common.save") })
            XCTAssertEqual(save.value("isAccessibilityEnabled") as? Bool, false)
            model.mcpDraftName = "Loading fixture"
            model.mcpDraftStdioCommand = "/usr/local/bin/example"
            model.mcpConnectionTestState = .testing
            try await SettingsBehaviorTestSupport.wait("MCP testing action disabled") {
                self.elements(in: content).contains {
                    $0.accessibilityLabel() == L("agent.mcp.testing") && $0.accessibilityRole() == .button
                        && $0.value("isAccessibilityEnabled") as? Bool == false
                }
            }
            let test = try XCTUnwrap(self.elements(in: content)
                .first { $0.accessibilityLabel() == L("agent.mcp.testing") && $0.accessibilityRole() == .button })
            XCTAssertEqual(test.value("isAccessibilityEnabled") as? Bool, false)
            let cancel = try XCTUnwrap(self.elements(in: content)
                .first { $0.accessibilityLabel() == L("common.cancel") })
            try self.click(cancel, in: sheet)
            try await SettingsBehaviorTestSupport.wait("MCP cancellation closes the sheet and clears testing") {
                window.attachedSheet == nil && model.mcpConnectionTestState == .idle
            }
            XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(model.mcpConnectionTestState, .idle)
            XCTAssertTrue(model.mcpServers.isEmpty)
        }
    }

    func testMCPTestAndCancelActionsUseCurrentDraft() async throws {
        let model = viewModel()
        model.beginAddMCPServer()
        model.mcpDraftName = "Invalid fixture"
        model.mcpDraftTransportType = .http
        model.mcpDraftHTTPURL = "://"
        var closed = false
        try await withWindow(MCPServerEditorView(viewModel: model) { closed = true }, width: 520,
                             height: 640) { window, hosting in
            let test = try XCTUnwrap(self.elements(in: hosting)
                .first { $0.accessibilityLabel() == L("agent.mcp.testConnection") })
            try self.click(test, in: window)
            for _ in 0 ..< 200
                where model.mcpConnectionTestState == .testing {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard case .failure = model.mcpConnectionTestState
            else { return XCTFail("Expected an invalid URL failure") }
            let cancel = try XCTUnwrap(self.elements(in: hosting)
                .first { $0.accessibilityLabel() == L("common.cancel") })
            try self.click(cancel, in: window)
            XCTAssertTrue(closed)
            XCTAssertTrue(model.mcpServers.isEmpty)
        }
    }

    func testGitHubInstallSheetKeepsPreviewAndWarningWithoutFixedIntroduction() async throws {
        let previousLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let tools = AskToolsSettingsView(
            settings: settings,
            installURL: "https://github.com/example/skills/tree/main/skills/demo"
        )
        for language in [AppLanguage.english, .simplifiedChinese] {
            AppLocalization.shared.setLanguage(language)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                try await render(
                    tools.installSheet,
                    name: "github-install",
                    language: language,
                    appearance: appearance,
                    width: 480,
                    height: 300
                )
            }
        }
    }

    func testMCPFormsRenderBothTransportsManyRowsAndFeedbackInBothLanguagesAndThemes() async throws {
        let previousLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let model = viewModel()
        for language in [AppLanguage.english, .simplifiedChinese] {
            AppLocalization.shared.setLanguage(language)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                model.beginAddMCPServer()
                try await render(MCPServerEditorView(viewModel: model, onClose: {}),
                                 name: "mcp-empty", language: language, appearance: appearance, width: 520, height: 640)
                model.mcpDraftName = "Example MCP"
                model.mcpDraftStdioCommand = "/usr/local/bin/example-mcp-server"
                model.mcpDraftStdioArgs = "--workspace /a/very/long/directory --verbose"
                model.mcpDraftStdioEnv = (0 ..< 12).map { "EXAMPLE_\($0)=value-\($0)" }.joined(separator: "\n")
                model.mcpConnectionTestState = .testing
                try await render(MCPServerEditorView(viewModel: model, onClose: {}),
                                 name: "mcp-stdio-many-rows", language: language, appearance: appearance, width: 520,
                                 height: 640)
                model.mcpDraftTransportType = .http
                model.mcpDraftHTTPURL = "https://mcp.example.com/a/very/long/path/with/many/segments"
                model.mcpDraftHTTPHeaders = "Authorization=fixture-secret\nX-Example=demo"
                model.mcpConnectionTestState = .failure(message: "Example connection failure")
                try await render(MCPServerEditorView(viewModel: model, onClose: {}),
                                 name: "mcp-http-error", language: language, appearance: appearance, width: 520,
                                 height: 640)
                model.mcpConnectionTestState = .success(tools: [.init(
                    id: "example",
                    name: "example",
                    description: "Example tool"
                )])
                model.mcpDraftEditingServerID = UUID()
                try await render(MCPServerEditorView(viewModel: model, onClose: {}),
                                 name: "mcp-http-success", language: language, appearance: appearance, width: 520,
                                 height: 640)
            }
        }
    }

    func testImageDraftAndModelFormsRenderAtNarrowAndDefaultWidths() async throws {
        let previousLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let store = AskImageSettings(defaults: settings.defaults, keys: .init(read: { _ in "" }, write: { _, _ in }))
        let images = AskImageSettingsModel(store: store)
        images.configuration.model = String(repeating: "custom-image-", count: 8)
        images.key = "fixture-secret"
        let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
        for language in [AppLanguage.english, .simplifiedChinese] {
            AppLocalization.shared.setLanguage(language)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for width in [CGFloat(520), 860] {
                    try await render(AskImageSettingsView(model: images).padding(24), name: "image-draft-\(Int(width))",
                                     language: language, appearance: appearance, width: width, height: 700)
                }
                try await render(AddModelEndpointView(library: library), name: "add-provider",
                                 language: language, appearance: appearance, width: 520, height: 460)
                try await render(
                    ModelSettingsPage(viewModel: viewModel(), library: library, speechDetail: { EmptyView() })
                        .padding(24),
                    name: "models",
                    language: language,
                    appearance: appearance,
                    width: 860,
                    height: 720
                )
                try await render(
                    ModelCatalogView(providerName: "Fixture", models: [], existingIDs: [], selected: .constant([]),
                                     onCancel: {}, onAdd: {}),
                    name: "catalog",
                    language: language,
                    appearance: appearance,
                    width: 580,
                    height: 470
                )
            }
        }
        XCTAssertTrue(images.hasChanges, "Rendering and leaving panes must not save the draft")
        XCTAssertEqual(store.key(for: images.configuration), "")
    }

    func testSharedFieldStylePreservesProgrammaticFocusAndKeyboardTraversal() async throws {
        try await withWindow(SettingsFocusFixture(), width: 320, height: 100) { window, _ in
            XCTAssertEqual((window.firstResponder as? NSTextView)?.string, "second-value")
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift],
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: window.windowNumber, context: nil,
                                                       characters: "\t", charactersIgnoringModifiers: "\t",
                                                       isARepeat: false, keyCode: 48))
            window.sendEvent(event)
            for _ in 0 ..< 10 {
                await Task.yield()
            }
            XCTAssertEqual((window.firstResponder as? NSTextView)?.string, "first-value")
        }
    }

    func testImageDraftSurvivesLeavingAndReturningToItsAgentPane() async throws {
        try await withWindow(StudioView(viewModel: viewModel()), width: 1100, height: 800) { window, hosting in
            @MainActor func open(_ pane: AgentSettingsPane) async throws {
                try await self.selectPane(pane, in: hosting)
                hosting.layoutSubtreeIfNeeded()
            }
            try await open(.imageGeneration)
            try await SettingsBehaviorTestSupport.wait("Image model field after native pane selection") {
                self.elements(in: hosting).contains { $0.accessibilityIdentifier() == "imagegen-model" }
            }
            let field = try XCTUnwrap(self.elements(in: hosting)
                .first { $0.accessibilityIdentifier() == "imagegen-model" })
            try self.click(field, in: window)
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            editor.selectAll(nil)
            editor.insertText("manual-unsaved-image-model", replacementRange: editor.selectedRange())
            try await Task.sleep(for: .milliseconds(100))
            try await open(.codeExecution)
            try await open(.imageGeneration)
            try await SettingsBehaviorTestSupport.wait("Restored unsaved image model after pane navigation") {
                self.elements(in: hosting).contains {
                    $0.accessibilityIdentifier() == "imagegen-model"
                        && $0.accessibilityValue() as? String == "manual-unsaved-image-model"
                }
            }
            let restored = try XCTUnwrap(self.elements(in: hosting)
                .first { $0.accessibilityIdentifier() == "imagegen-model" })
            XCTAssertEqual(restored.accessibilityValue() as? String, "manual-unsaved-image-model")
            XCTAssertNotNil(self.elements(in: hosting)
                .first {
                    $0.accessibilityValue() as? String == L("imagegen.unsaved") || $0
                        .accessibilityLabel() == L("imagegen.unsaved")
                })
            XCTAssertNotEqual(
                AskImageSettings(defaults: self.settings.defaults).configuration.model,
                "manual-unsaved-image-model"
            )
        }
    }

    func testImageSaveActionCommitsDraftAndKeyRevealHasAccessibleName() async throws {
        var savedKey = ""
        let store = AskImageSettings(
            defaults: settings.defaults,
            keys: .init(read: { _ in savedKey }, write: { _, value in savedKey = value })
        )
        let model = AskImageSettingsModel(store: store)
        model.key = "fixture-key"
        model.configuration.model = "manual-custom-image"
        var callbacks = 0
        try await withWindow(AskImageSettingsView(model: model) { _, _ in
            callbacks += 1
        }, width: 700, height: 600) { window, hosting in
            let save = try XCTUnwrap(self.elements(in: hosting)
                .first { $0.accessibilityLabel() == L("ask.models.save") })
            try self.click(save, in: window)
            try await SettingsBehaviorTestSupport.wait("Image settings save callback") {
                !model.hasChanges && callbacks == 1
            }
            XCTAssertFalse(model.hasChanges)
            XCTAssertEqual(store.configuration.model, "manual-custom-image")
            XCTAssertEqual(savedKey, "fixture-key")
            XCTAssertEqual(callbacks, 1)
            try await SettingsBehaviorTestSupport.wait("Accessible API Key reveal control") {
                self.elements(in: hosting).contains { $0.accessibilityLabel() == L("models.showKey") }
            }
            let reveal = try XCTUnwrap(self.elements(in: hosting)
                .first { $0.accessibilityLabel() == L("models.showKey") })
            try self.click(reveal, in: window)
            try await SettingsBehaviorTestSupport.wait("Accessible API Key hide control") {
                self.elements(in: hosting).contains { $0.accessibilityLabel() == L("models.hideKey") }
            }
            XCTAssertNotNil(self.elements(in: hosting).first { $0.accessibilityLabel() == L("models.hideKey") })
            model.select(.openAI)
            model.key = "fixture-openai-key"
            model.loading = true
            try await SettingsBehaviorTestSupport.wait("Disabled image model refresh action") {
                self.elements(in: hosting).contains {
                    $0.accessibilityLabel() == L("imagegen.models.refresh")
                        && $0.accessibilityRole() == .button && $0.value("isAccessibilityEnabled") as? Bool == false
                }
            }
            let refresh = try XCTUnwrap(self.elements(in: hosting).first {
                $0.accessibilityLabel() == L("imagegen.models.refresh") && $0.accessibilityRole() == .button
            })
            XCTAssertEqual(refresh.value("isAccessibilityEnabled") as? Bool, false)
        }
    }

    func testMCPFooterRemainsVisibleAndSavePersistsBothTransportForms() async throws {
        let model = viewModel()
        for transport in [MCPTransportType.stdio, .http] {
            model.beginAddMCPServer()
            model.mcpDraftName = "Fixture-\(transport)"
            model.mcpDraftTransportType = transport
            model.mcpDraftStdioCommand = "/usr/local/bin/example"
            model.mcpDraftStdioEnv = (0 ..< 20).map { "EXAMPLE_\($0)=value-\($0)" }.joined(separator: "\n")
            model.mcpDraftHTTPURL = "https://mcp.example.com/sse"
            model.mcpDraftHTTPHeaders = "Authorization=fixture"
            var closed = false
            try await withWindow(MCPServerEditorView(viewModel: model) { closed = true }, width: 520,
                                 height: 640) { window, hosting in
                let save = try XCTUnwrap(self.elements(in: hosting)
                    .first { $0.accessibilityLabel() == L("common.save") })
                XCTAssertTrue(
                    window.frame.contains(save.accessibilityFrame()),
                    "Save must stay visible below a long scrolling form"
                )
                try self.click(save, in: window)
                for _ in 0 ..< 10 {
                    await Task.yield()
                }
                XCTAssertTrue(closed)
                let saved = try XCTUnwrap(model.mcpServers.last)
                switch (transport, saved.transport) {
                case let (.stdio, .stdio(configuration)):
                    XCTAssertEqual(configuration.env.count, 20)
                    XCTAssertEqual(configuration.command, "/usr/local/bin/example")
                case let (.http, .http(configuration)):
                    XCTAssertEqual(configuration.url, "https://mcp.example.com/sse")
                    XCTAssertEqual(configuration.headers["Authorization"], "fixture")
                default: XCTFail("Save used the wrong transport")
                }
            }
        }
    }

    func testPageLayoutsAtMinimumAndDefaultWindowHeights() async throws {
        let previousLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        for language in [AppLanguage.english, .simplifiedChinese] {
            settings.appLanguage = language
            AppLocalization.shared.setLanguage(language)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for section in [StudioSection.agent, .models] {
                    for height in [CGFloat(620), 800] {
                        let model = viewModel()
                        model.navigate(to: section)
                        try await render(StudioView(viewModel: model), name: "page-\(section.rawValue)-\(Int(height))",
                                         language: language, appearance: appearance, width: 1100, height: height)
                    }
                }
            }
        }
    }

    /// SwiftUI's accessibility nodes expose selectors without adopting NSAccessibilityProtocol.
    private struct Element {
        let object: NSObject
        func value(_ key: String) -> Any? {
            SettingsBehaviorTestSupport.Element(object: object).value(key)
        }

        func accessibilityLabel() -> String? {
            SettingsBehaviorTestSupport.Element(object: object).label
        }

        func accessibilityIdentifier() -> String? {
            value("accessibilityIdentifier") as? String
        }

        func accessibilityValue() -> Any? {
            value("accessibilityValue")
        }

        func accessibilityRole() -> NSAccessibility.Role? {
            NSAccessibility.Role(rawValue: SettingsBehaviorTestSupport.Element(object: object).role)
        }

        func accessibilityFrame() -> NSRect {
            SettingsBehaviorTestSupport.Element(object: object).frame
        }
    }

    private func elements(in element: Any) -> [Element] {
        SettingsBehaviorTestSupport.elements(in: element).map { Element(object: $0.object) }
    }

    private func selectPane(_ pane: AgentSettingsPane, in host: NSView) async throws {
        let window = try XCTUnwrap(host.window)
        try await SettingsBehaviorTestSupport.wait("Native Agent pane row: \(pane.title)") {
            self.paneRow(pane, in: host) != nil
        }
        let (table, row) = try XCTUnwrap(paneRow(pane, in: host))
        // UI System v2 uses List(selection:), with native selection notifications.
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        try await SettingsBehaviorTestSupport.wait("Agent pane navigation: \(pane.title)") {
            window.title.contains(pane.title)
        }
    }

    private func paneRow(_ pane: AgentSettingsPane, in host: NSView) -> (NSTableView, Int)? {
        host.layoutSubtreeIfNeeded()
        for table in SettingsBehaviorTestSupport.nativeViews(in: host).compactMap({ $0 as? NSTableView }) {
            guard table.window === host.window, !table.isHiddenOrHasHiddenAncestor else { continue }
            for row in 0 ..< table.numberOfRows {
                let cells = (0 ..< table.numberOfColumns).compactMap {
                    table.view(atColumn: $0, row: row, makeIfNecessary: true)
                }
                let values = cells.flatMap {
                    SettingsBehaviorTestSupport.nativeViews(in: $0).flatMap {
                        SettingsBehaviorTestSupport.elements(in: $0)
                    }
                }
                if values.contains(where: {
                    $0.value("accessibilityIdentifier") as? String == "settings.pane.\(pane.id)"
                        || $0.text == pane.title || $0.label == pane.title || $0.label.hasPrefix(pane.title + ", ")
                }) { return (table, row) }
            }
        }
        return nil
    }

    private func click(_ element: Element, in window: NSWindow) throws {
        if let role = element.accessibilityRole(), [.button, .radioButton, .checkBox].contains(role) {
            try SettingsBehaviorTestSupport.Element(object: element.object, window: window).press()
            return
        }
        let frame = element.accessibilityFrame()
        XCTAssertFalse(frame.isEmpty, "A clickable control needs a visible frame")
        func fields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        let content = try XCTUnwrap(window.contentView)
        let field = try XCTUnwrap(fields(in: content).first {
            $0.isEditable && window.convertToScreen($0.convert($0.bounds, to: nil)).intersects(frame)
        }, "Missing native editable field for the accessibility element")
        // Focus directly: mouseDown/nextEvent tracking can stop the Swift Testing host's outer runloop.
        XCTAssertTrue(window.makeFirstResponder(field))
    }

    private func withWindow(_ content: some View, width: CGFloat, height: CGFloat,
                            check: (NSWindow, NSView) async throws -> Void) async throws {
        try await TypefluxNavigationTestSupport.withWindow(content,
            size: NSSize(width: width, height: height), run: check)
    }

    func testConfigurationLabelsAreLocalizedAndMCPStillShowsConnectionResults() {
        let previousLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        for language in AppLanguage.allCases {
            AppLocalization.shared.setLanguage(language)
            XCTAssertNotEqual(L("models.configured"), "models.configured")
            XCTAssertNotEqual(L("imagegen.unsaved"), "imagegen.unsaved")
            XCTAssertNotEqual(L("agent.mcp.kv.key"), "agent.mcp.kv.key")
            XCTAssertEqual(MCPServerStatusPresentation(enabled: true, result: .success(tools: [])).state, .connected)
        }
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        XCTAssertEqual(L("models.configured"), "已配置")
    }

    private func height(_ content: some View) -> CGFloat {
        NSHostingView(rootView: content.frame(width: 280)).fittingSize.height
    }

    private func render(_ content: some View, name: String, language: AppLanguage, appearance: NSAppearance.Name,
                        width: CGFloat, height: CGFloat) async throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: content.frame(width: width, height: height, alignment: .topLeading)
            .background(TypefluxColor.windowBackground.color))
        window.contentView = hosting
        window.orderFront(nil)
        defer { TypefluxNavigationTestSupport.closeWindow(window) }
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 4000)
        if let output = ProcessInfo.processInfo.environment["TYPEFLUX_SETTINGS_POLISH_SNAPSHOTS"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png
                .write(to: directory
                    .appendingPathComponent(
                        "\(name)-\(language.rawValue)-\(appearance == .aqua ? "light" : "dark").png"
                    ))
        }
    }
}

private struct SettingsFocusFixture: View {
    enum Field: Hashable { case first, second }
    @State private var first = "first-value"
    @State private var second = "second-value"
    @FocusState private var focused: Field?

    var body: some View {
        VStack {
            TextField("First", text: $first).textFieldStyle(.roundedBorder).focused(
                $focused,
                equals: .first
            )
            TextField("Second", text: $second).textFieldStyle(.roundedBorder).focused(
                $focused,
                equals: .second
            )
        }
        .onAppear { focused = .second }
    }
}
