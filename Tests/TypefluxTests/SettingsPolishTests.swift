import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

@MainActor
final class SettingsPolishTests: XCTestCase {
    private var suite: String!
    private var root: URL!
    private var settings: SettingsStore!

    override func setUp() {
        _ = NSApplication.shared
        // SwiftUI exposes its accessibility tree only while assistive clients request it.
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        suite = "settings-polish-" + UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() {
        settings.defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func viewModel() -> StudioViewModel {
        StudioViewModel(
            settingsStore: settings,
            historyStore: SQLiteHistoryStore(baseDir: root),
            initialSection: .agent,
            modelLibrary: AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
        )
    }

    func testFieldsSearchMenusAndActionsHaveMatchingIntrinsicHeights() {
        let field = height(TextField("Name", text: .constant("long example name"))
            .textFieldStyle(ModelFieldStyle(monospaced: false)))
        XCTAssertEqual(field, 30, accuracy: 0.5)
        XCTAssertEqual(
            height(SecureField("Key", text: .constant("fixture")).textFieldStyle(ModelFieldStyle())),
            field,
            accuracy: 0.5
        )
        XCTAssertEqual(height(SettingsSearchBox(placeholder: "Search", text: .constant(""))), field, accuracy: 0.5)
        XCTAssertEqual(height(SettingsSearchBox(placeholder: "Search", text: .constant("query"))), field, accuracy: 0.5)
        XCTAssertEqual(
            height(SettingsMenuPicker(
                title: "Protocol",
                options: [(label: "Responses", value: 1)],
                selection: .constant(1)
            )),
            field,
            accuracy: 0.5
        )
        XCTAssertEqual(height(Button("Save") {}.buttonStyle(ModelActionStyle(primary: true))), field, accuracy: 0.5)
        let plainCard = height(StudioTextInputCard(label: "Name", placeholder: "Name", text: .constant("value")))
        XCTAssertEqual(
            height(StudioTextInputCard(label: "Key", placeholder: "Key", text: .constant("value"), secure: true)),
            plainCard,
            accuracy: 0.5
        )
        XCTAssertEqual(
            height(StudioSuggestedTextInputCard(
                label: "Model",
                placeholder: "Model",
                text: .constant("manual-model"),
                suggestions: ["suggested-model"]
            )),
            plainCard,
            accuracy: 0.5
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
            let tab = try XCTUnwrap(self.elements(in: hosting).first {
                $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? "")
                    .hasPrefix(AgentSettingsPane.mcpServers.title)
            })
            try self.click(tab, in: window)
            try await Task.sleep(for: .milliseconds(100))
            let add = try XCTUnwrap(self.elements(in: hosting)
                .first { $0.accessibilityLabel() == L("agent.mcp.addServer") })
            try self.click(add, in: window)
            try await Task.sleep(for: .milliseconds(150))
            let sheet = try XCTUnwrap(window.attachedSheet)
            let content = try XCTUnwrap(sheet.contentView)
            let save = try XCTUnwrap(self.elements(in: content).first { $0.accessibilityLabel() == L("common.save") })
            XCTAssertEqual(save.value("isAccessibilityEnabled") as? Bool, false)
            model.mcpDraftName = "Loading fixture"
            model.mcpDraftStdioCommand = "/usr/local/bin/example"
            try await Task.sleep(for: .milliseconds(100))
            model.mcpConnectionTestState = .testing
            try await Task.sleep(for: .milliseconds(100))
            let test = try XCTUnwrap(self.elements(in: content)
                .first { $0.accessibilityLabel() == L("agent.mcp.testing") && $0.accessibilityRole() == .button })
            XCTAssertEqual(test.value("isAccessibilityEnabled") as? Bool, false)
            let cancel = try XCTUnwrap(self.elements(in: content)
                .first { $0.accessibilityLabel() == L("common.cancel") })
            try self.click(cancel, in: sheet)
            try await Task.sleep(for: .milliseconds(200))
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

    func testSearchClearActionHasAccessibleNameAndUpdatesBinding() async throws {
        var query = "model query"
        let search = SettingsSearchBox(
            placeholder: "Search fixture",
            text: Binding(get: { query }, set: { query = $0 })
        )
        try await withWindow(search, width: 280, height: 40) { window, hosting in
            let button = try XCTUnwrap(self.elements(in: hosting)
                .first { $0.accessibilityLabel() == L("common.clear") })
            try self.click(button, in: window)
            for _ in 0 ..< 10 {
                await Task.yield()
            }
            XCTAssertEqual(query, "")
        }
    }

    func testImageDraftSurvivesLeavingAndReturningToItsAgentPane() async throws {
        try await withWindow(StudioView(viewModel: viewModel()), width: 1100, height: 800) { window, hosting in
            @MainActor func open(_ pane: AgentSettingsPane) async throws {
                let button = try XCTUnwrap(self.elements(in: hosting).first {
                    $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? "").hasPrefix(pane.title)
                })
                try self.click(button, in: window)
                try await Task.sleep(for: .milliseconds(100))
                hosting.layoutSubtreeIfNeeded()
            }
            try await open(.imageGeneration)
            let field = try XCTUnwrap(self.elements(in: hosting)
                .first { $0.accessibilityIdentifier() == "imagegen-model" })
            try self.click(field, in: window)
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            editor.selectAll(nil)
            editor.insertText("manual-unsaved-image-model", replacementRange: editor.selectedRange())
            try await Task.sleep(for: .milliseconds(100))
            try await open(.codeExecution)
            try await open(.imageGeneration)
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
            for _ in 0 ..< 10 {
                await Task.yield()
            }
            XCTAssertFalse(model.hasChanges)
            XCTAssertEqual(store.configuration.model, "manual-custom-image")
            XCTAssertEqual(savedKey, "fixture-key")
            XCTAssertEqual(callbacks, 1)
            let reveal = try XCTUnwrap(self.elements(in: hosting)
                .first { $0.accessibilityLabel() == L("models.showKey") })
            try self.click(reveal, in: window)
            for _ in 0 ..< 10 {
                await Task.yield()
            }
            XCTAssertNotNil(self.elements(in: hosting).first { $0.accessibilityLabel() == L("models.hideKey") })
            model.select(.openAI)
            model.key = "fixture-openai-key"
            model.loading = true
            try await Task.sleep(for: .milliseconds(100))
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
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }

        func accessibilityLabel() -> String? {
            value("accessibilityLabel") as? String
        }

        func accessibilityIdentifier() -> String? {
            value("accessibilityIdentifier") as? String
        }

        func accessibilityValue() -> Any? {
            value("accessibilityValue")
        }

        func accessibilityRole() -> NSAccessibility.Role? {
            (value("accessibilityRole") as? String).map(NSAccessibility.Role.init(rawValue:))
        }

        func accessibilityFrame() -> NSRect {
            (value("accessibilityFrame") as? NSValue)?.rectValue ?? .zero
        }
    }

    private func elements(in element: Any) -> [Element] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: Any) -> [Element] {
            guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let element = Element(object: object)
            return [element] + (element.value("accessibilityChildren") as? [Any] ?? []).flatMap(walk)
        }
        return walk(element)
    }

    private func click(_ element: Element, in window: NSWindow) throws {
        let frame = element.accessibilityFrame()
        XCTAssertFalse(frame.isEmpty, "A clickable control needs a visible frame")
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        // Native text fields track until mouse-up; queue it before dispatching mouse-down.
        try NSApp.postEvent(event(.leftMouseUp), atStart: true)
        try NSApp.sendEvent(event(.leftMouseDown))
        if let release = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(release)
        }
    }

    private func withWindow(_ content: some View, width: CGFloat, height: CGFloat,
                            check: (NSWindow, NSView) async throws -> Void) async throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: content.frame(width: width, height: height, alignment: .topLeading))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        try await check(window, hosting)
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
            .background(ModelVisualStyle.canvas))
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
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
            TextField("First", text: $first).textFieldStyle(ModelFieldStyle(monospaced: false)).focused(
                $focused,
                equals: .first
            )
            TextField("Second", text: $second).textFieldStyle(ModelFieldStyle(monospaced: false)).focused(
                $focused,
                equals: .second
            )
        }
        .onAppear { focused = .second }
    }
}
