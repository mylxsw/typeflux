import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("World clock in the real launcher", .serialized, .exclusiveUIState)
@MainActor
struct WorldClockLauncherIntegrationTests {
    private static func prepare(_ model: AskConversationModel) {
        model.worldClock = WorldClockLauncherModel(directory: WorldClockFixtures.directory,
                                                   clock: { WorldClockFixtures.now },
                                                   localZone: { WorldClockFixtures.shanghai })
    }

    @Test func `keyword registration and settings`() {
        #expect(AskPluginRegistry.pluginIDs.contains(AskWorldClockPlugin.id))
        let defaults = AskPluginRegistry.defaultKeywords.filter { $0.pluginID == AskWorldClockPlugin.id }
        #expect(defaults.map(\.allKeywords) == [["tz", "时间", "时区", "世界时钟", "worldclock"]])
        #expect(AskKeywordMatcher.match("tz 伦敦", keywords: defaults) == .active(defaults[0], argument: "伦敦"))
        let known = AskPluginRegistry.coveredGroups.filter { $0 != AskWorldClockPlugin.id }
        let migrated = AskPluginRegistry.keywords(saved: [AskKeyword(keyword: "cal", pluginID: AskCalendarPlugin.id)],
                                                  known: known)
        #expect(migrated.contains { $0.pluginID == AskWorldClockPlugin.id && $0.keyword == "tz" })
        #expect(AskKeywordKind(pluginID: AskWorldClockPlugin.id) == .worldClock)
        #expect(AskKeywordKind.worldClock.pluginID == AskWorldClockPlugin.id)
        #expect(AskKeywordKind.worldClock.symbol == "globe" && !AskKeywordKind.worldClock.title.isEmpty)
        #expect(AskKeywordSection.typeflux.kinds.contains(.worldClock))
        let draft = AskKeywordDraft(editing: .init(keyword: "tz", pluginID: AskWorldClockPlugin.id,
                                                   options: [WorldClockPreferences.stepOption: "15", "custom": "kept"]))
        #expect(draft.kind == .worldClock && draft.fieldProblem == nil && draft.titlePlaceholder.isEmpty)
        #expect(draft.result().options == [WorldClockPreferences.stepOption: "15", "custom": "kept"])
        #expect(!draft.displayName.isEmpty)
        #expect(!AskKeywordListPresentation.name(of: defaults[0]).isEmpty)
        #expect(!AskKeywordListPresentation.summary(of: defaults[0], interface: .english, secondLanguage: "en").isEmpty)
    }

    @Test func `plugin runs locally without selected text`() async throws {
        let plugin = AskWorldClockPlugin()
        #expect(plugin.entersOnReturn && plugin.runsWithoutInput && !plugin.usesSelectionInput)
        #expect(plugin.defaultKeywords == AskWorldClockPlugin.keywords && plugin.symbol == "globe")
        #expect(plugin.keywordColor == AskTheme.accent && !plugin.title.isEmpty)
        #expect(!plugin.placeholder(selectionLines: 2).isEmpty)
        #expect(plugin.chipDetail(for: plugin.defaultKeywords[0], language: .english) == nil)
        let request = AskPluginRequest(text: "伦敦", origin: .argument, keyword: plugin.defaultKeywords[0], options: [:],
                                       interfaceLanguage: .english)
        let plan = await plugin.plan(request)
        #expect(plan.mode == .live && plan.debounce == .zero)
        #expect(try await plugin.run(request, plan: plan, progress: { _ in }).body == "伦敦")
        var selection = request
        selection.origin = .selection
        #expect(try await plugin.run(selection, plan: plan, progress: { _ in }).body.isEmpty)
        #expect(plugin.nextOptions(after: plan, request: request, step: 1) == nil)
    }

    @Test func `keys from the editor drive the clock and save the list`() async throws {
        try await AskQuickResultsInteractionTests().withPasteboard { pasteboard in
            let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "tz", prepare: Self.prepare)
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await launcher.press(36)
            #expect(model.plugins.keyword?.pluginID == AskWorldClockPlugin.id)
            #expect(model.launcherDraft.text.isEmpty)
            let clock = model.worldClock
            #expect(clock.query == .list && clock.listCities.first?.id == "shanghai")
            try await launcher.press(124)
            #expect(clock.moment == WorldClockFixtures.utc("2026-10-22T10:30:00Z"))
            try await launcher.press(17, .command)
            #expect(clock.isAtNow)
            try await launcher.press(125)
            #expect(clock.selection == 1)
            try await launcher.press(8, .command)
            #expect(pasteboard.string(forType: .string) == clock.copyText)
            #expect(launcher.dismissed == 0)
            try await launcher.press(125, .option)
            let saved = model.modelLibrary.settings.effectiveAskLauncherKeywords(reserving: [])
                .first { $0.pluginID == AskWorldClockPlugin.id }
            let order = WorldClockPreferences(options: saved?.options ?? [:]).cityIDs
            #expect(order.first == clock.preferences.cityIDs.first && clock.selection == 2)
            try await launcher.press(51, .command)
            #expect(clock.removed != nil)
            try await launcher.press(6, .command)
            #expect(clock.removed == nil)

            model.launcherDraft.text = "15:00 London to Tokyo"
            try await Task.sleep(for: .milliseconds(80))
            if case .convert = clock.query {} else { Issue.record("conversion: \(clock.query)") }
            try await launcher.press(36)
            #expect(pasteboard.string(forType: .string) == clock.copyText)
            try await launcher.press(53)
            #expect(model.launcherDraft.text.isEmpty && model.plugins.isActive)
            try await launcher.press(53)
            #expect(!model.plugins.isActive && model.launcherDraft.text == "tz")
            try await launcher.press(53)
            #expect(launcher.dismissed == 1)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func `adding from search and inserting write back`() async throws {
        try await AskQuickResultsInteractionTests().withPasteboard { _ in
            let launcher = try await AskQuickResultsInteractionTests.Launcher(
                text: "tz kathmandu", waitForSearch: false, prepare: Self.prepare
            )
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await launcher.fixture.wait { model.plugins.isActive && model.worldClock.chosenCity?.id == "kathmandu" }
            try await launcher.press(36)
            #expect(model.launcherDraft.text.isEmpty)
            #expect(model.worldClock.preferences.cityIDs.contains("kathmandu"))
            let saved = model.modelLibrary.settings.effectiveAskLauncherKeywords(reserving: [])
                .first { $0.pluginID == AskWorldClockPlugin.id }
            let savedCities = WorldClockPreferences(options: saved?.options ?? [:]).cityIDs
            #expect(savedCities.contains("kathmandu"))
            #expect(model.performWorldClockEffect(.handled) == .stay)
            #expect(model.performWorldClockEffect(.clearInput) == .stay)
        }
    }
}

@Suite("World clock visuals", .serialized, .exclusiveUIState)
@MainActor
struct WorldClockLauncherVisualTests {
    // swiftlint:disable:next function_body_length
    @Test func `renders every state in the production launcher`() async throws {
        _ = NSApplication.shared
        let old = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(old) }
        let options = [WorldClockPreferences.citiesOption: #"["sanfrancisco","newyork","london","tokyo","sydney"]"#,
                       WorldClockPreferences.labelsOption: #"{"london":"设计团队","newyork":"Maya"}"#,
                       WorldClockPreferences.hourFormatOption: "24"]
        for (scene, text, light) in [
            ("list", "", false), ("scrub", "", false), ("detail", "", false), ("search", "ban", false),
            ("convert", "明天 9am 纽约", false), ("meeting", "北京 纽约 伦敦", false), ("overlap", "北京 东京", false),
            ("timestamp", "1792405440", false), ("unknown", "火星", false), ("light-list", "", true),
            ("light-meeting", "北京 纽约 伦敦", true)
        ] {
            let fixture = try AskTestFixture()
            let clock = WorldClockLauncherModel(directory: WorldClockFixtures.directory,
                                                clock: { WorldClockFixtures.now },
                                                localZone: { WorldClockFixtures.shanghai })
            fixture.model.worldClock = clock
            var keyword = try #require(fixture.model.plugins.availableKeywords
                .first { $0.pluginID == AskWorldClockPlugin.id })
            keyword.options = options
            fixture.model.plugins.enter(keyword)
            fixture.model.launcherDraft.text = text
            let size = NSSize(width: AskMetrics.launcherWidth, height: AskMetrics.launcherWindowHeight)
            let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                            backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            let host = NSHostingView(rootView: AskLauncherView(model: fixture.model, onDismiss: {},
                                                               onHeightChange: { _ in }))
            host.frame = NSRect(origin: .zero, size: size)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { clock.close(); window.close(); fixture.model.resetSession() }
            try await fixture.wait { clock.preferences.labels["london"] != nil }
            switch scene {
            case "list": clock.select(2)
            case "scrub":
                clock.select(2)
                for _ in 0 ..< 6 { clock.step(1) }
            case "detail": clock.select(3)
            default: break
            }
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide >= 680 && bitmap.pixelsHigh >= 500)
            #expect(clock.query == WorldClockFixtures.parser.parse(text))
            if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_WORLDCLOCK_SNAPSHOTS"] {
                let url = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent(scene + ".png"))
            }
        }
    }

    @Test func `chip and hint row name the mode and the times`() throws {
        let old = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(old) }
        let model = WorldClockLauncherModel(directory: WorldClockFixtures.directory, clock: { WorldClockFixtures.now },
                                            localZone: { WorldClockFixtures.shanghai })
        defer { model.close() }
        for text in ["", "london", "Atlantis", "9am london", "Beijing Tokyo", "now"] {
            model.activate(text: text, options: WorldClockFixtures.listOptions, language: .english)
            let host = NSHostingView(rootView: HStack {
                WorldClockKeywordChip(model: model)
                WorldClockHintSummary(options: WorldClockFixtures.listOptions)
            }.frame(width: 640, height: 40))
            host.frame = NSRect(x: 0, y: 0, width: 640, height: 40)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide >= 640)
        }
    }

    @Test func `settings view renders the city list`() async throws {
        let old = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(old) }
        var options = [WorldClockPreferences.citiesOption: #"["newyork","london"]"#,
                       WorldClockPreferences.labelsOption: #"{"newyork":"Maya"}"#]
        let binding = Binding(get: { options }, set: { options = $0 })
        let host = NSHostingView(rootView: WorldClockKeywordSettingsView(options: binding)
            .frame(width: 520).padding().background(StudioTheme.surfaceMuted))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 560)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= 560)
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_WORLDCLOCK_SNAPSHOTS"] {
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings.png"))
        }
    }
}
