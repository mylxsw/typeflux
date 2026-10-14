import Foundation
import Testing
@testable import Typeflux

@Suite("Screenshot keyword", .exclusiveUIState)
@MainActor
struct AskScreenshotPluginTests {
    private func request(_ keyword: AskKeyword, options: [String: String]? = nil) -> AskPluginRequest {
        AskPluginRequest(text: "", origin: .argument, keyword: keyword, options: options ?? keyword.options,
                         interfaceLanguage: .english)
    }

    private let region = AskScreenshotPlugin.keywords[0]
    private let fullScreen = AskScreenshotPlugin.keywords[2]
    private let scrolling = AskScreenshotPlugin.keywords[3]

    @Test func `keywords and registration`() {
        #expect(AskScreenshotPlugin.keywords.map(\.keyword) == ["jt", "截图", "jtqp", "jtgd", "jtai", "lp", "录屏", "gif"])
        #expect(AskPluginRegistry.pluginIDs.contains(AskScreenshotPlugin.id))
        let defaults = AskPluginRegistry.defaultKeywords.filter { $0.pluginID == AskScreenshotPlugin.id }
        // `jt` and `截图` do the same thing, so they become one entry with an alias.
        #expect(defaults.map(\.allKeywords) == [["jt", "截图"], ["jtqp"], ["jtgd"], ["jtai"], ["lp", "录屏"], ["gif"]])
        let plugin = AskScreenshotPlugin()
        #expect(plugin.runsWithoutInput && !plugin.usesSelectionInput && plugin.entersOnReturn)
        #expect(plugin.title == L("screenshot.title") && plugin.symbol == "camera.viewfinder")
        #expect(plugin.optionName == L("screenshot.plugin.option"))
        #expect(plugin.placeholder(selectionLines: 2) == L("screenshot.plugin.placeholder"))
    }

    @Test func `saved keyword lists gain the screenshot keywords`() {
        let saved = [AskKeyword(keyword: "fy", pluginID: AskTranslatePlugin.id)]
        let known = AskPluginRegistry.coveredGroups.filter { $0 != AskScreenshotPlugin.id }
        let keywords = AskPluginRegistry.keywords(saved: saved, known: known)
        #expect(keywords.contains { $0.pluginID == AskScreenshotPlugin.id && $0.contains("jt") })
    }

    @Test func `return starts the mode of the keyword`() async {
        let plugin = AskScreenshotPlugin(isPermissionGranted: { true })

        let regionPlan = await plugin.plan(request(region))
        #expect(regionPlan.mode == .onSubmit)
        #expect(regionPlan.title == L("screenshot.mode.region"))
        #expect(regionPlan.meta.isEmpty)
        #expect(regionPlan.action(for: .enter)?.kind == .capture(mode: .region))

        let fullPlan = await plugin.plan(request(fullScreen))
        #expect(fullPlan.title == L("screenshot.mode.fullScreen"))
        #expect(fullPlan.action(for: .enter)?.kind == .capture(mode: .fullScreen))

        let scrollingPlan = await plugin.plan(request(scrolling))
        #expect(scrollingPlan.title == L("screenshot.mode.scrolling"))
        #expect(scrollingPlan.action(for: .enter)?.kind == .capture(mode: .scrolling))
    }

    @Test func `missing permission is shown on the chip and the plan`() async {
        let plugin = AskScreenshotPlugin(isPermissionGranted: { false })

        #expect(plugin.chipDetail(for: region, language: .english) == L("screenshot.permission.needed"))
        let plan = await plugin.plan(request(region))
        #expect(plan.meta == [AskPluginMeta(text: L("screenshot.permission.needed"), emphasized: true)])
        #expect(plan.action(for: .enter)?.kind == .capture(mode: .region), "Return still starts, to show the guide")

        let granted = AskScreenshotPlugin(isPermissionGranted: { true })
        #expect(granted.chipDetail(for: region, language: .english) == nil)
        #expect(granted.chipDetail(for: fullScreen, language: .english) == L("screenshot.mode.fullScreen.short"))
        #expect(granted.chipDetail(for: scrolling, language: .english) == L("screenshot.mode.scrolling.short"))
        #expect(AskConversationModel.chipTitle(plugin: plugin, keyword: region, language: .english)
            == L("screenshot.title") + " · " + L("screenshot.permission.needed"))
        #expect(AskConversationModel.chipTitle(plugin: granted, keyword: region, language: .english)
            == L("screenshot.title"))
        #expect(AskConversationModel.chipTitle(plugin: granted, keyword: fullScreen, language: .english)
            == L("screenshot.title") + " · " + L("screenshot.mode.fullScreen.short"))
    }

    @Test func `tab switches between modes`() async {
        let plugin = AskScreenshotPlugin(isPermissionGranted: { true })
        let plan = await plugin.plan(request(region))

        #expect(plugin.nextOptions(after: plan, request: request(region), step: 1) == ["mode": "fullScreen"])
        #expect(plugin.nextOptions(after: plan, request: request(fullScreen), step: 1) == ["mode": "scrolling"])
        #expect(plugin.nextOptions(after: plan, request: request(scrolling), step: 1) == ["mode": "region"])
        #expect(plugin.nextOptions(after: plan, request: request(region), step: -1) == ["mode": "scrolling"])
        #expect(plugin.nextOptions(after: plan, request: request(region, options: [:]), step: 3) == ["mode": "region"])
    }

    @Test func `recording keywords route and cycle formats`() async throws {
        let plugin = AskScreenshotPlugin(isPermissionGranted: { true })
        let video = try #require(AskScreenshotPlugin.keywords.first { $0.keyword == "lp" })
        let gif = try #require(AskScreenshotPlugin.keywords.first { $0.keyword == "gif" })
        #expect(AskScreenshotPlugin.captureKind(for: video) == .capture(mode: .recording))
        #expect(AskScreenshotPlugin.captureKind(for: gif) == .capture(mode: .gif))
        #expect(plugin.chipDetail(for: video, language: .english) == L("recording.title"))
        #expect(plugin.chipDetail(for: gif, language: .english) == L("recording.gif"))
        let plan = await plugin.plan(request(video))
        #expect(plan.title == L("recording.title"))
        #expect(plugin.nextOptions(after: plan, request: request(video), step: 1) == ["mode": "gif"])
        #expect(plugin.nextOptions(after: plan, request: request(gif), step: 1) == ["mode": "recording"])
        #expect(AskScreenshotPlugin.title(of: .gif) == L("recording.gif"))
    }

    @Test func `running directly is not possible`() async {
        let plugin = AskScreenshotPlugin(isPermissionGranted: { true })
        let plan = await plugin.plan(request(region))
        await #expect(throws: CancellationError.self) {
            _ = try await plugin.run(request(region), plan: plan) { _ in }
        }
    }

    @Test func `mode options fall back to region`() {
        #expect(ScreenshotMode(options: [:]) == .region)
        #expect(ScreenshotMode(options: ["mode": "bogus"]) == .region)
        #expect(ScreenshotMode(options: ["mode": "fullScreen"]) == .fullScreen)
        #expect(ScreenshotMode(options: ["mode": "scrolling"]) == .scrolling)
    }

    @Test func `capture action closes the launcher then starts`() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let model = fixture.model
        let action = AskPluginAction(kind: .capture(mode: .fullScreen), title: "", symbol: "")

        #expect(model.performPluginAction(action) == .stay, "Nothing to start without the app's coordinator")

        var started: [ScreenshotMode] = []
        model.onStartScreenshot = { mode, _ in started.append(mode) }
        #expect(model.performPluginAction(action) == .close)
        #expect(started.isEmpty, "Starts only after the launcher has closed")
        for _ in 0 ..< 100 where started.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(started == [.fullScreen])
    }
}
