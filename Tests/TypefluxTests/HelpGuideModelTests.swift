import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Supplies the tracking area SwiftUI needs without moving the user's pointer.
private final class HelpRowHoverEvent: NSEvent {
    private let area: NSTrackingArea
    private let point: NSPoint
    private let targetWindowNumber: Int
    private let eventType: NSEvent.EventType

    init(area: NSTrackingArea, point: NSPoint, window: NSWindow, inside: Bool) {
        self.area = area
        self.point = point
        targetWindowNumber = window.windowNumber
        eventType = inside ? .mouseEntered : .mouseExited
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override var trackingArea: NSTrackingArea? { area }
    override var locationInWindow: NSPoint { point }
    override var windowNumber: Int { targetWindowNumber }
    override var type: NSEvent.EventType { eventType }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// What the model's sources return, changed by the tests.
final class HelpModelTestState {
    var keywords: [AskKeyword] = [HelpCatalogTests.translate, HelpCatalogTests.polish,
                                  HelpCatalogTests.summarize, HelpCatalogTests.lock]
    var permissions: [HelpPermissionStatus] = []
    var refreshes = 0
}

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct HelpGuideModelTests {
    /// Records what the guide asked the app to do.
    final class Recorder {
        var closes = 0
        var tried: [(AskKeyword, String)] = []
        var asked: [String] = []
        var launcherOpens = 0
        var settings: [HelpSettingsDestination] = []
        var fixed: [PrivacyGuard.PermissionID] = []
        var feedback: [FeedbackDestination] = []
        var urls: [URL] = []
    }

    struct Harness {
        let model: HelpGuideModel
        let settings: SettingsStore
        let center: NotificationCenter
        let workflows: PassthroughSubject<Void, Never>
        let recorder: Recorder
        let state: HelpModelTestState
    }

    func harness() throws -> Harness {
        let defaults = try #require(UserDefaults(suiteName: "help-model-" + UUID().uuidString))
        let settings = SettingsStore(defaults: defaults)
        let center = NotificationCenter()
        let workflows = PassthroughSubject<Void, Never>()
        let state = HelpModelTestState()
        let model = HelpGuideModel(sources: .init(
            keywords: { _ in state.keywords.map { HelpCatalogTests.source($0, selection: true) } },
            usage: { [:] },
            settings: settings,
            permissions: { state.permissions },
            refreshWorkflows: { state.refreshes += 1 },
            workflowChanges: workflows.eraseToAnyPublisher()
        ), center: center)
        let recorder = Recorder()
        model.actions = .init(
            close: { recorder.closes += 1 },
            tryKeyword: { recorder.tried.append(($0, $1)) },
            askAI: { recorder.asked.append($0) },
            openLauncher: { recorder.launcherOpens += 1 },
            openSettings: { recorder.settings.append($0) },
            fixPermission: { recorder.fixed.append($0) },
            openFeedback: { recorder.feedback.append($0) },
            openURL: { recorder.urls.append($0) }
        )
        return Harness(model: model, settings: settings, center: center, workflows: workflows,
                       recorder: recorder, state: state)
    }

    func settle() async {
        for _ in 0 ..< 5 { await Task.yield() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    @Test(arguments: InterfaceStyle.allCases, [false, true])
    func `row descriptions use independent settings popovers`(style: InterfaceStyle, selectable: Bool) async throws {
        let ui = SettingsBehaviorTestSupport.self
        let detail = "A long description that should remain available without adding a second line to the guide row."
        var selections = 0
        try await ui.withFixture { _ in
            let row = HelpRow(symbol: "keyboard", title: "Guide item", detail: detail,
                              action: selectable ? { selections += 1 } : nil) {
                HelpKeycaps(keys: ["⌘", "K"])
            }
            let plain = HelpRow(symbol: "keyboard", title: "Guide item") {
                HelpKeycaps(keys: ["⌘", "K"])
            }
            func height(_ view: some View) -> CGFloat {
                let host = NSHostingView(rootView: view.environment(\.interfaceStyle, style).frame(width: 500))
                host.layoutSubtreeIfNeeded()
                return host.fittingSize.height
            }
            #expect(abs(height(row) - height(plain)) < 0.5, "Descriptions must not add a line to list rows")
            try await ui.withWindow(row.environment(\.interfaceStyle, style), width: 500, height: 100) { window, host in
                window.setFrameOrigin(NSPoint(x: 80, y: 80))
                #expect(!ui.elements(in: host).contains {
                    $0.role == NSAccessibility.Role.staticText.rawValue && $0.text == detail
                })
                #expect(!ui.elements(in: host).contains { $0.label == detail })
                try hover(NSPoint(x: 20, y: 50), in: window, inside: true)
                try await ui.wait { ui.elements(in: host).contains { $0.label == detail } }
                let hint = try ui.button(detail, in: host)
                let point = window.convertPoint(fromScreen: NSPoint(x: hint.frame.midX, y: hint.frame.midY))
                try hover(point, in: window, inside: true)
                try await ui.wait {
                    NSApp.windows.contains { $0.isVisible && $0.parent === window && ui.contains(detail, in: $0) }
                }
                #expect(selections == 0, "Opening help must not select or run the row")
                try hover(point, in: window, inside: false)
                try await ui.wait {
                    !NSApp.windows.contains { $0.isVisible && $0.parent === window && ui.contains(detail, in: $0) }
                }
                try hover(NSPoint(x: 20, y: 50), in: window, inside: true)
                try await ui.wait { ui.elements(in: host).contains { $0.label == detail } }
                try ui.button(detail, in: host).press()
                try await ui.wait {
                    NSApp.windows.contains { $0.isVisible && $0.parent === window && ui.contains(detail, in: $0) }
                }
                #expect(selections == 0)
                try hint.press()
                try await ui.wait {
                    !NSApp.windows.contains { $0.isVisible && $0.parent === window && ui.contains(detail, in: $0) }
                }
                if selectable {
                    try ui.button("Guide item", in: host).press()
                    #expect(selections == 1)
                }
            }
            try await ui.withWindow(plain.environment(\.interfaceStyle, style), width: 500, height: 100) { _, host in
                #expect(!ui.elements(in: host).contains { $0.role == NSAccessibility.Role.button.rawValue })
            }
        }
    }

    private func hover(_ point: NSPoint, in window: NSWindow, inside: Bool) throws {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var delivered = false
        for view in descendants(try #require(window.contentView)) {
            for area in view.trackingAreas {
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                guard rect.contains(view.convert(point, from: nil)), let owner = area.owner as? NSResponder else { continue }
                let event = HelpRowHoverEvent(area: area, point: point, window: window, inside: inside)
                if inside { owner.mouseEntered(with: event) } else { owner.mouseExited(with: event) }
                delivered = true
            }
        }
        #expect(delivered, "Guide rows must expose native hover tracking areas")
    }

    @Test func `opening starts fresh on the start page or searching`() async throws {
        let kit = try harness()
        kit.model.page = .faq
        kit.model.filter = .system
        kit.model.prepare(query: "")
        #expect(kit.model.page == .start && kit.model.filter == nil && kit.model.isPresented)
        #expect(kit.model.catalog.keywords.count == 4)
        #expect(kit.model.selectedKeywordID == HelpCatalogTests.translate.pluginID + ":fy")
        await settle()
        #expect(kit.state.refreshes == 1, "workflows are read again each time the guide opens")
        kit.model.prepare(query: "rw")
        #expect(kit.model.isSearching && kit.model.query == "rw")
        #expect(kit.model.searchItems.first == .keyword(kit.model.catalog.keywords[1]))
    }

    @Test func `changed shortcuts keywords and workflows show at once while presented`() async throws {
        let kit = try harness()
        kit.model.prepare(query: "")
        #expect(kit.model.catalog.shortcuts(in: .global).first { $0.target == .action(.openHelp) }?.keys == nil)
        kit.settings.setHotkey(HelpCatalogTests.controlOptionR, for: .openHelp)
        // The store posts on the default center; the model listens to the one it was given.
        kit.center.post(name: .hotkeySettingsDidChange, object: nil)
        await settle()
        #expect(kit.model.catalog.shortcuts(in: .global).first { $0.target == .action(.openHelp) }?.keys
            == ["⌃", "⌥", "R"])
        kit.state.keywords.append(HelpCatalogTests.workflow)
        kit.workflows.send(())
        await settle()
        #expect(kit.model.catalog.keywords(in: .mine).map(\.keyword.keyword) == ["ip"])
        kit.state.keywords.append(HelpCatalogTests.japanese)
        kit.center.post(name: .askLauncherSearchSettingsDidChange, object: nil)
        await settle()
        #expect(kit.model.catalog.keywords(in: .mine).count == 2)
        kit.model.dismissed()
        kit.state.keywords = []
        kit.center.post(name: .askLauncherSearchSettingsDidChange, object: nil)
        await settle()
        #expect(kit.model.catalog.keywords.count == 6, "a closed guide does not rebuild")
    }

    @Test func `escape clears the search before closing`() throws {
        let kit = try harness()
        kit.model.prepare(query: "fy")
        #expect(kit.model.handle(.escape) && kit.model.query.isEmpty && kit.recorder.closes == 0)
        #expect(kit.model.handle(.escape) && kit.recorder.closes == 1)
    }

    @Test func `command numbers switch pages and find focuses the field`() throws {
        let kit = try harness()
        kit.model.prepare(query: "x")
        let request = kit.model.focusRequest
        #expect(kit.model.handle(.page(3)) && kit.model.page == .shortcuts && !kit.model.isSearching)
        #expect(!kit.model.handle(.page(9)))
        #expect(kit.model.handle(.find) && kit.model.focusRequest == request + 1)
    }

    @Test func `arrows move through keywords and return tries the selected one`() throws {
        let kit = try harness()
        kit.model.prepare(query: "")
        #expect(!kit.model.handle(.down), "the start page has no list to move through")
        kit.model.show(.keywords)
        #expect(kit.model.handle(.down))
        #expect(kit.model.selectedKeyword?.keyword == HelpCatalogTests.polish)
        kit.model.handle(.up)
        kit.model.handle(.up)
        #expect(kit.model.selectedKeyword?.keyword == HelpCatalogTests.translate)
        #expect(kit.model.handle(.enter))
        #expect(kit.recorder.closes == 0 && kit.recorder.tried.map(\.0) == [HelpCatalogTests.translate])
        #expect(kit.recorder.tried.first?.1 == "")
        #expect(kit.model.handle(.commandEnter) && kit.recorder.tried.count == 2)
    }

    @Test func `an unavailable keyword is not tried`() throws {
        let kit = try harness()
        kit.model.prepare(query: "")
        var keyword = try #require(kit.model.catalog.keywords.first)
        keyword.keyword.enabled = false
        kit.model.tryKeyword(keyword, argument: "hello")
        #expect(kit.recorder.tried.isEmpty && kit.recorder.closes == 0)
        kit.model.tryKeyword(try #require(kit.model.catalog.keywords.first), argument: "hello")
        #expect(kit.recorder.tried.first?.1 == "hello")
    }

    @Test func `search results move and open where they belong`() throws {
        let kit = try harness()
        kit.model.prepare(query: "s")
        let items = kit.model.searchItems
        #expect(items.count > 1)
        #expect(kit.model.handle(.down) && kit.model.searchFocus == 1)
        for _ in 0 ..< items.count + 2 { kit.model.handle(.down) }
        #expect(kit.model.searchFocus == items.count - 1)
        kit.model.query = "rw"
        #expect(kit.model.searchFocus == 0, "a new query starts at the top")
        #expect(kit.model.handle(.enter))
        #expect(kit.model.page == .keywords && !kit.model.isSearching)
        #expect(kit.model.selectedKeyword?.keyword == HelpCatalogTests.polish)
        kit.model.query = "cmd k"
        #expect(kit.model.handle(.enter) && kit.model.page == .shortcuts)
        let question = try #require(kit.model.catalog.questions.last)
        kit.model.open(.question(question))
        #expect(kit.model.page == .faq && kit.model.openQuestionID == question.id)
        kit.model.open(.command(HelpCommand(name: "/help", title: "")))
        #expect(kit.model.page == .shortcuts)
    }

    @Test func `nothing found offers the question to the AI`() throws {
        let kit = try harness()
        kit.model.prepare(query: "  sync to my phone ")
        #expect(kit.model.searchResults.isEmpty && !kit.model.handle(.enter))
        #expect(kit.model.handle(.commandEnter))
        #expect(kit.recorder.asked == ["sync to my phone"] && kit.recorder.closes == 0)
        #expect(kit.model.query == "  sync to my phone " && kit.model.isPresented)
        kit.model.query = ""
        kit.model.askAI()
        #expect(kit.recorder.asked.count == 1)
    }

    @Test func `a missing permission marks the questions it explains`() throws {
        let kit = try harness()
        kit.state.permissions = [
            HelpPermissionStatus(id: .microphone, title: "Mic", detail: "", granted: true),
            HelpPermissionStatus(id: .accessibility, title: "AX", detail: "Required", granted: false)
        ]
        kit.model.prepare(query: "")
        #expect(kit.model.missingPermissions.map(\.id) == [.accessibility])
        #expect(kit.model.relevantQuestions.map(\.id) == ["voiceNoResponse", "textNotInserted"])
        #expect(kit.model.openQuestionID == "voiceNoResponse", "the first likely answer is open")
        let unrelated = try #require(kit.model.catalog.questions.first { $0.id == "privacy" })
        #expect(!kit.model.isRelevant(unrelated))
        kit.model.toggleQuestion("voiceNoResponse")
        #expect(kit.model.openQuestionID == nil)
        kit.model.fix(.accessibility)
        #expect(kit.recorder.fixed == [.accessibility] && kit.recorder.closes == 0)
        kit.state.permissions[1].granted = true
        kit.model.reloadPermissions()
        #expect(kit.model.missingPermissions.isEmpty && kit.model.relevantQuestions.isEmpty)
    }

    @Test func `filters keep a visible selection`() throws {
        let kit = try harness()
        kit.model.prepare(query: "")
        kit.model.show(.keywords)
        kit.model.setFilter(.system)
        #expect(kit.model.visibleKeywords.map(\.keyword) == [HelpCatalogTests.lock])
        #expect(kit.model.selectedKeyword?.keyword == HelpCatalogTests.lock)
        kit.model.setFilter(nil)
        #expect(kit.model.selectedKeyword?.keyword == HelpCatalogTests.lock, "a selection still visible stays")
        kit.model.showKeyword(HelpCatalogTests.polish.pluginID + ":rw")
        #expect(kit.model.page == .keywords && kit.model.selectedKeyword?.keyword == HelpCatalogTests.polish)
    }

    @Test func `actions on every page keep the guide and its navigation state open`() throws {
        let kit = try harness()
        let controller = HelpWindowController(settingsStore: kit.settings, model: kit.model)
        kit.model.actions.close = { [weak controller] in kit.recorder.closes += 1; controller?.dismiss() }
        controller.show(query: "")
        defer { controller.dismiss() }
        let window = try #require(controller.presentedWindow)
        let keyword = try #require(kit.model.selectedKeyword)
        for page in HelpPage.allCases {
            kit.model.show(page)
            let selectedID = kit.model.selectedKeywordID
            kit.model.openSettings(.shortcuts)
            kit.model.open(HelpGuideModel.documentationURL)
            kit.model.fix(.accessibility)
            kit.model.openLauncher()
            kit.model.tryKeyword(keyword, argument: "hello world")
            for choice in FeedbackDestination.allCases { kit.model.openFeedback(choice) }
            #expect(kit.model.page == page && kit.model.selectedKeywordID == selectedID)
            kit.model.query = "  sync to my phone "
            kit.model.askAI()
            #expect(kit.model.query == "  sync to my phone ")
            #expect(controller.presentedWindow === window && kit.model.isPresented)
            #expect(kit.recorder.closes == 0)
        }
        #expect(kit.recorder.launcherOpens == HelpPage.allCases.count)
        #expect(kit.recorder.tried.count == HelpPage.allCases.count)
        #expect(kit.recorder.settings.count == HelpPage.allCases.count)
        #expect(kit.recorder.feedback == HelpPage.allCases.flatMap { _ in FeedbackDestination.allCases })
        #expect(kit.recorder.urls.allSatisfy { $0 == HelpGuideModel.documentationURL })
        kit.model.query = ""
        kit.model.handle(.escape)
        #expect(kit.recorder.closes == 1 && !controller.isPresented && !kit.model.isPresented)
    }

    @Test(arguments: InterfaceStyle.allCases)
    func `the start page has a static voice card and a working launcher card`(style: InterfaceStyle) async throws {
        try await SettingsBehaviorTestSupport.withFixture { _ in
            let kit = try harness()
            kit.model.prepare(query: "")
            try await SettingsBehaviorTestSupport.withWindow(
                HelpWindowView(model: kit.model).environment(\.interfaceStyle, style), width: 1120, height: 740
            ) { _, host in
                let ui = SettingsBehaviorTestSupport.self
                try await ui.wait { ui.contains(L("help.start.voice.title"), in: host) }
                #expect(!ui.elements(in: host).contains {
                    $0.role == NSAccessibility.Role.button.rawValue && $0.label == L("help.start.voice.title")
                })
                try ui.button(L("help.start.launcher.title"), in: host).press()
                #expect(kit.recorder.launcherOpens == 1 && kit.recorder.closes == 0)
                if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_HELP_RENDER_SNAPSHOT"] {
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(
                        to: URL(fileURLWithPath: directory).appendingPathComponent(style.rawValue + "-start.png")
                    )
                }
            }
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func `the sidebar feedback menu offers and dispatches all three choices`(style: InterfaceStyle) async throws {
        try await SettingsBehaviorTestSupport.withFixture { _ in
            let kit = try harness()
            kit.settings.interfaceStyle = style
            let controller = HelpWindowController(settingsStore: kit.settings, model: kit.model)
            kit.model.actions.close = { [weak controller] in kit.recorder.closes += 1; controller?.dismiss() }
            controller.show(query: "")
            defer { controller.dismiss() }
            let window = try #require(controller.presentedWindow)
            let host = try #require(window.contentView)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            try await SettingsBehaviorTestSupport.wait {
                descendants(host).contains { $0 is NSPopUpButton }
            }
            // Render the menu's actual content without AppKit's tracking loop, which
            // can terminate the SwiftPM host before it reports test completion.
            try await SettingsBehaviorTestSupport.withWindow(VStack {
                HelpFeedbackOptions(model: kit.model)
            }, width: 300, height: 180) { _, options in
                for choice in FeedbackDestination.allCases {
                    try SettingsBehaviorTestSupport.button(choice.title, in: options).press()
                    #expect(kit.recorder.feedback.last == choice)
                    #expect(controller.presentedWindow === window && kit.recorder.closes == 0)
                }
            }
            #expect(kit.recorder.feedback == FeedbackDestination.allCases && kit.recorder.urls.isEmpty)
        }
    }

    @Test func `keys map to the guide's actions`() {
        #expect(HelpWindowController.key(keyCode: 53, characters: "", command: false) == .escape)
        #expect(HelpWindowController.key(keyCode: 126, characters: "", command: false) == .up)
        #expect(HelpWindowController.key(keyCode: 125, characters: "", command: false) == .down)
        #expect(HelpWindowController.key(keyCode: 36, characters: "\r", command: false) == .enter)
        #expect(HelpWindowController.key(keyCode: 76, characters: "\r", command: true) == .commandEnter)
        #expect(HelpWindowController.key(keyCode: 3, characters: "f", command: true) == .find)
        #expect(HelpWindowController.key(keyCode: 19, characters: "2", command: true) == .page(2))
        #expect(HelpWindowController.key(keyCode: 23, characters: "5", command: true) == nil)
        #expect(HelpWindowController.key(keyCode: 3, characters: "f", command: false) == nil)
    }

    @Test func `the window has room for its two columns`() {
        #expect(HelpWindowView.defaultSize.width >= HelpWindowView.minimumSize.width)
        #expect(HelpWindowView.defaultSize.height >= HelpWindowView.minimumSize.height)
        #expect(HelpWindowView.minimumSize.width > HelpWindowView.sidebarWidth + 600)
    }

    @Test func `the guide title uses the localized usage guide name without a brand`() {
        for language in AppLanguage.allCases {
            let title = AppLocalization.shared.string("help.title", in: language)
            #expect(title == AppLocalization.shared.string("ask.plugin.help.title", in: language))
            #expect(!title.localizedCaseInsensitiveContains("Typeflux"))
        }
        #expect(AppLocalization.shared.string("help.title", in: .simplifiedChinese) == "使用指南")
    }

    @Test func `examples suit what the keyword takes`() throws {
        let catalog = HelpCatalog.build(HelpCatalogTests.input())
        let translate = try #require(catalog.keywords.first { $0.keyword == HelpCatalogTests.translate })
        #expect(HelpKeywordDetail.examples(translate) == ["fy " + L("help.keyword.example.translate"), "fy"])
        let lock = try #require(catalog.keywords.first { $0.keyword == HelpCatalogTests.lock })
        #expect(HelpKeywordDetail.examples(lock) == ["lockscreen"])
        let files = try #require(catalog.keywords.first { $0.keyword == HelpCatalogTests.files })
        #expect(HelpKeywordDetail.examples(files) == ["f " + L("help.keyword.example.search")])
    }

    @Test func `the guide renders every page in both interface styles`() throws {
        let kit = try harness()
        kit.state.permissions = [
            HelpPermissionStatus(id: .accessibility, title: "AX", detail: "Required", granted: false)
        ]
        kit.model.prepare(query: "")
        for style in InterfaceStyle.allCases {
            for page in HelpPage.allCases {
                kit.model.show(page)
                try render(kit.model, style: style)
            }
            kit.model.query = "rw"
            try render(kit.model, style: style)
            kit.model.query = "nothing-like-this"
            try render(kit.model, style: style)
            kit.model.query = ""
        }
    }

    @Test func `the guide is a normal window that takes keys and closes`() throws {
        let kit = try harness()
        let controller = HelpWindowController(settingsStore: kit.settings, model: kit.model)
        kit.model.actions.close = { [weak controller] in kit.recorder.closes += 1; controller?.dismiss() }
        #expect(!controller.isPresented && controller.presentedWindow == nil)
        controller.dismiss()
        controller.show(query: "")
        defer { controller.dismiss() }
        let panel = try #require(controller.presentedWindow)
        #expect(controller.isPresented && kit.model.isPresented)
        #expect(panel.level == .normal && panel.styleMask.contains(.titled) && panel.styleMask.contains(.resizable))
        #expect(panel.styleMask.contains(.closable) && panel.contentMinSize.width == HelpWindowView.minimumSize.width)
        #expect(panel.frameAutosaveName == HelpWindowController.frameAutosaveName)
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                          windowNumber: panel.windowNumber, context: nil, characters: characters,
                                          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        panel.makeFirstResponder(nil)
        #expect(controller.handle(try key(0, "a")) && kit.model.query == "a", "typing anywhere searches")
        #expect(controller.handle(try key(20, "3", .command)) && kit.model.page == .shortcuts && kit.model.query.isEmpty)
        #expect(!controller.handle(try key(14, "e", .control)), "control chords are not typed into the search")
        #expect(controller.handle(try key(53, "\u{1b}")))
        #expect(kit.recorder.closes == 1 && !controller.isPresented && !kit.model.isPresented)
        controller.show(query: "fy")
        #expect(controller.isPresented && kit.model.query == "fy", "the same window opens again")
        #expect(controller.presentedWindow === panel)
    }

    /// When `TYPEFLUX_HELP_SNAPSHOT` names a folder, writes the real panel as shown on screen, with
    /// the launcher's real keywords and the Chinese interface, for every page in both styles and
    /// appearances. On-screen capture is the only way to see Liquid Glass as the app draws it.
    @Test func `snapshots for design review`() throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_HELP_SNAPSHOT"] else { return }
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previous) }
        let fixture = try AskTestFixture()
        let defaults = try #require(UserDefaults(suiteName: "help-snapshot-" + UUID().uuidString))
        let settings = SettingsStore(defaults: defaults)
        settings.keywordHotkeys = [
            KeywordHotkey(binding: HelpCatalogTests.controlOptionR, keyword: "rw", pluginID: AskPromptPlugin.id)
        ]
        let model = HelpGuideModel(sources: .init(
            keywords: { fixture.model.helpKeywordSources(language: $0) },
            usage: { ["fy": 42, "rw": 26, "f": 15, "g": 11, "jt": 9, "clip": 5] },
            settings: settings,
            permissions: {
                [PrivacyGuard.PermissionID.microphone, .accessibility].map {
                    HelpPermissionStatus(id: $0, title: $0.title, detail: L("permission.accessibility.detail.required"),
                                         granted: $0 == .microphone)
                }
            }
        ))
        for style in InterfaceStyle.allCases {
            for dark in [true, false] {
                settings.interfaceStyle = style
                settings.appearanceMode = dark ? .dark : .light
                for page in HelpPage.allCases {
                    try capture(model, settings: settings, query: "", page: page,
                                to: Self.snapshotURL(directory, style: style, dark: dark, name: page.rawValue))
                }
                try capture(model, settings: settings, query: "截图", page: .start,
                            to: Self.snapshotURL(directory, style: style, dark: dark, name: "search"))
            }
        }
    }

    private func capture(_ model: HelpGuideModel, settings: SettingsStore, query: String, page: HelpPage,
                         to url: URL) throws {
        let controller = HelpWindowController(settingsStore: settings, model: model)
        controller.show(query: query)
        defer { controller.dismiss() }
        if query.isEmpty { model.show(page) }
        let panel = try #require(controller.presentedWindow)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(panel.windowNumber)", url.path]
        try process.run()
        process.waitUntilExit()
    }

    static func snapshotURL(_ directory: String, style: InterfaceStyle, dark: Bool, name: String) -> URL {
        let file = "\(style.rawValue)-\(dark ? "dark" : "light")-\(name).png"
        return URL(fileURLWithPath: directory).appendingPathComponent(file)
    }

    private func render(_ model: HelpGuideModel, style: InterfaceStyle) throws {
        let view = HelpWindowView(model: model).environment(\.interfaceStyle, style)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        #expect(rep.pixelsWide > 0)
    }
}
