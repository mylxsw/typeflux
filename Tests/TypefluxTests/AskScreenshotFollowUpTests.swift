import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Typeflux

/// Reads a fixed text, or fails, counting the calls.
private final class StubRecognizer: ImageTextRecognizing, @unchecked Sendable {
    var lines: [String]
    var fails = false
    private(set) var calls = 0

    init(_ lines: [String]) { self.lines = lines }

    func recognizeText(in source: ImageTextSource) async throws -> RecognizedText {
        calls += 1
        if fails { throw ImageTilingError.unreadable }
        return RecognizedText(lines: lines.enumerated().map { index, text in
            RecognizedText.Line(text: text, confidence: 1,
                                boundingBox: CGRect(x: 0, y: CGFloat(index) * 0.1, width: 1, height: 0.05))
        })
    }
}

@Suite("Screenshot follow-ups in the launcher", .exclusiveUIState)
@MainActor
struct AskScreenshotFollowUpTests {
    private func image(width: Int = 400, height: Int = 200) -> ScreenshotFollowUpImage {
        ScreenshotFollowUpImage(image: ScreenCaptureTestSupport.image(width: width, height: height), scale: 2,
                                isLongImage: false)
    }

    private func source(_ lines: [String], fits: Bool = true) -> AskScreenshotTextSource {
        let recognizer = StubRecognizer(lines)
        let file = URL(fileURLWithPath: "/x")
        return AskScreenshotTextSource(pixelSize: CGSize(width: 536, height: 256), fitsQuestion: fits,
                                       recognition: Task { try await recognizer.recognizeText(in: .url(file)) })
    }

    private func request(_ keyword: AskKeyword = AskScreenshotTextPlugin.keywords[0]) -> AskPluginRequest {
        AskPluginRequest(text: "", origin: .argument, keyword: keyword, options: keyword.options,
                         interfaceLanguage: .english)
    }

    // MARK: Text plugin

    @Test func theTextKeywordsAreRegistered() {
        #expect(AskScreenshotTextPlugin.keywords.map(\.keyword) == ["ocr", "取字"])
        #expect(AskPluginRegistry.pluginIDs.contains(AskScreenshotTextPlugin.id))
        let defaults = AskPluginRegistry.defaultKeywords.filter { $0.pluginID == AskScreenshotTextPlugin.id }
        #expect(defaults.map(\.allKeywords) == [["ocr", "取字"]])
        let plugin = AskScreenshotTextPlugin()
        #expect(plugin.runsWithoutInput && !plugin.usesSelectionInput && plugin.entersOnReturn)
        #expect(plugin.title == L("screenshot.text.title") && plugin.symbol == "text.viewfinder")
        #expect(plugin.placeholder(selectionLines: nil) == L("screenshot.text.placeholder"))
        #expect(plugin.optionName == nil)
        #expect(plugin.defaultKeywords == AskScreenshotTextPlugin.keywords)
    }

    @Test func savedKeywordListsGainTheNewKeywords() {
        let saved = [AskKeyword(keyword: "fy", pluginID: AskTranslatePlugin.id)]
        let known = AskPluginRegistry.coveredGroups.filter {
            $0 != AskScreenshotTextPlugin.id && $0 != AskPluginRegistry.screenshotAskKeywords
        }
        let keywords = AskPluginRegistry.keywords(saved: saved, known: known)
        #expect(keywords.contains { $0.pluginID == AskScreenshotTextPlugin.id && $0.contains("ocr") })
        #expect(keywords.contains { $0.pluginID == AskScreenshotPlugin.id && $0.contains("jtai") })
        #expect(!keywords.contains { $0.contains("jt") }, "Only the groups added since")
        #expect(AskPluginRegistry.group(of: AskScreenshotPlugin.keywords[4]) == AskPluginRegistry.screenshotAskKeywords)
        #expect(AskPluginRegistry.group(of: AskScreenshotPlugin.keywords[0]) == AskScreenshotPlugin.id)
    }

    @Test func withoutAScreenshotReturnTakesOne() async {
        let plugin = AskScreenshotTextPlugin(isPermissionGranted: { true })
        let plan = await plugin.plan(request())
        #expect(plan.mode == .onSubmit)
        #expect(plan.meta.isEmpty)
        #expect(plan.action(for: .enter)?.kind == .capture(mode: .region, followUp: .recognizeText))
        #expect(plan.action(for: .enter)?.title == L("screenshot.action.start"))
        await #expect(throws: CancellationError.self) {
            _ = try await plugin.run(request(), plan: plan) { _ in }
        }
        #expect(plugin.nextOptions(after: plan, request: request(), step: 1) == nil)

        let denied = AskScreenshotTextPlugin(isPermissionGranted: { false })
        #expect(await denied.plan(request()).meta == [AskPluginMeta(text: L("screenshot.permission.needed"),
                                                                     emphasized: true)])
        #expect(denied.chipDetail(for: AskScreenshotTextPlugin.keywords[0], language: .english)
            == L("screenshot.permission.needed"))
        #expect(plugin.chipDetail(for: AskScreenshotTextPlugin.keywords[0], language: .english) == nil)
    }

    @Test func theWaitingScreenshotsTextIsTheResultWithItsKeys() async throws {
        let shown = source(["活跃用户 128,430", "联系人：张三"])
        let plugin = AskScreenshotTextPlugin(screenshot: { shown }, savesNotes: true)
        let plan = await plugin.plan(request())
        #expect(plan.mode == .live)
        #expect(plan.debounce == .zero)
        #expect(plan.values[AskScreenshotTextPlugin.sourceValue] == shown.id.uuidString)

        let output = try await plugin.run(request(), plan: plan) { _ in }
        let text = "活跃用户 128,430\n联系人：张三"
        #expect(output.body == text)
        #expect(output.meta == [AskPluginMeta(text: L("screenshot.text.meta", 2, "536 × 256 px"))])
        #expect(output.meta[0].text.contains("536 × 256 px"))
        #expect(output.source == L("screenshot.text.source"))
        #expect(output.action(for: .enter)?.kind == .copy(text))
        #expect(output.action(for: .optionEnter)?.kind == .writeBack(text))
        #expect(output.action(for: .tab)?.kind == .translate(text))
        #expect(output.action(for: .commandR)?.kind == .capture(mode: .region, followUp: .recognizeText))
        #expect(output.action(for: .commandR)?.title == L("screenshot.text.recapture"))
        #expect(output.askAIAction?.kind == .screenshotFollowUp(.askAI))
        guard case let .toggleNote(draft)? = output.action(for: .commandS)?.kind else {
            Issue.record("⌘S saves a note")
            return
        }
        #expect(draft.body == text && draft.keyword == "ocr")
        #expect(output.starred == false)
    }

    @Test func aScreenshotTooLongForAQuestionIsAskedAboutByItsText() async throws {
        let shown = source(["line"], fits: false)
        let plugin = AskScreenshotTextPlugin(screenshot: { shown })
        let plan = await plugin.plan(request())
        let output = try await plugin.run(request(), plan: plan) { _ in }
        #expect(output.askAIAction?.kind == .askAI(L("screenshot.text.askAI", "line")))
        #expect(output.action(for: .commandS) == nil, "No notes without the store")
        #expect(output.starred == nil)
    }

    @Test func noTextShowsTheEmptyStateWithItsWaysOn() async throws {
        let shown = source([" "])
        let plugin = AskScreenshotTextPlugin(screenshot: { shown })
        let plan = await plugin.plan(request())
        do {
            _ = try await plugin.run(request(), plan: plan) { _ in }
            Issue.record("Expected the empty state")
        } catch let failure as AskPluginFailure {
            #expect(failure.message == L("screenshot.text.empty"))
            #expect(!failure.retry)
            #expect(failure.action(for: .commandR)?.kind == .capture(mode: .region, followUp: .recognizeText))
            #expect(failure.askAIAction?.kind == .screenshotFollowUp(.askAI))
        }
    }

    @Test func aRunForAnotherScreenshotStops() async {
        let first = source(["one"]), second = source(["two"])
        var current = first
        let plugin = AskScreenshotTextPlugin(screenshot: { current })
        let plan = await plugin.plan(request())
        current = second
        await #expect(throws: CancellationError.self) {
            _ = try await plugin.run(request(), plan: plan) { _ in }
        }
    }

    // MARK: Screenshot keyword

    @Test func jtaiFramesARegionForTheAI() async {
        let plugin = AskScreenshotPlugin(isPermissionGranted: { true })
        let jtai = AskScreenshotPlugin.keywords[4]
        let plan = await plugin.plan(request(jtai))
        #expect(plan.title == L("screenshot.mode.askAI"))
        #expect(plan.action(for: .enter)?.kind == .capture(mode: .region, followUp: .askAI))
        #expect(plugin.chipDetail(for: jtai, language: .english) == L("screenshot.followUp.askAI"))

        #expect(AskScreenshotPlugin.startsCapture(jtai))
        #expect(AskScreenshotPlugin.startsCapture(AskScreenshotTextPlugin.keywords[1]))
        #expect(!AskScreenshotPlugin.startsCapture(AskKeyword(keyword: "fy", pluginID: AskTranslatePlugin.id)))
        #expect(AskScreenshotPlugin.captureKind(for: jtai) == .capture(mode: .region, followUp: .askAI))
        #expect(AskScreenshotPlugin.captureKind(for: AskScreenshotPlugin.keywords[2]) == .capture(mode: .fullScreen))
        #expect(AskScreenshotPlugin.captureKind(for: AskScreenshotTextPlugin.keywords[0])
            == .capture(mode: .region, followUp: .recognizeText))
        #expect(ScreenshotFollowUp(options: [:]) == nil)
        #expect(ScreenshotFollowUp(options: ["followUp": "nope"]) == nil)
    }

    // MARK: Actions and keys

    @Test func askingTheAIAboutAScreenshotIsWhatCommandReturnDoes() {
        let ask = AskPluginAction(kind: .screenshotFollowUp(.askAI), title: "", symbol: "")
        #expect(ask.asksAI)
        #expect(AskPluginAction(kind: .askAI("x"), title: "", symbol: "").asksAI)
        #expect(!AskPluginAction(kind: .screenshotFollowUp(.translate), title: "", symbol: "").asksAI)
        #expect(AskPluginFailure(message: "", actions: [ask]).askAIAction == ask)
        #expect(AskPluginFailure(message: "").askAIAction == nil)
        #expect(AskPluginResultsView.key(.tab) == "⇥")
    }

    @Test func theBottomBarNamesWhatTabDoes() {
        let output = AskPluginOutput(body: "text", original: "", meta: [], source: "", actions: [
            AskPluginAction(kind: .copy("text"), title: "Copy", symbol: "", shortcut: .enter),
            AskPluginAction(kind: .translate("text"), title: "Translate", symbol: "", shortcut: .tab)
        ])
        let plan = AskPluginPlan(mode: .live, title: "")
        let display = AskPluginDisplay(title: "", symbol: "", phase: .done(plan, output), offersAskAI: false)
        #expect(AskPluginResultsView.hint(for: display).contains(L("ask.plugin.hint.option", "Translate")))
    }

    // MARK: Attachments

    @Test func aScreenshotBecomesOneOrSeveralImageAttachments() throws {
        let one = try AskScreenshotAttachments.make(image()).get()
        #expect(one.count == 1)
        #expect(one[0].kind == .image && one[0].name == L("screenshot.ask.attachmentName"))
        #expect(one[0].image?.hasPrefix("data:image/jpeg;base64,") == true)
        #expect(one[0].screenshot == true)

        let long = try AskScreenshotAttachments.make(image(width: 600, height: 5000)).get()
        #expect(long.count == 3)
        #expect(long.map(\.name) == (1 ... 3).map { L("screenshot.ask.attachmentPart", $0, 3) })
        #expect(long.allSatisfy { $0.screenshot == true })
        #expect(long.reduce(0) { $0 + $1.payloadBytes } <= AskAttachmentLimits.maximumPayloadBytes)

        #expect(AskScreenshotAttachments.make(image(width: 600, height: 40000)) == .failure(.tooLong(22)))
        #expect(AskScreenshotAttachments.make(image(width: 600, height: 5000), maximumCount: 2)
            == .failure(.tooLong(3)))
    }

    @Test func piecesAreShrunkToTheAttachmentSize() throws {
        let wide = ScreenCaptureTestSupport.image(width: 4096, height: 1000)
        let shrunk = try #require(AskScreenshotAttachments.shrink(wide, longEdge: 2048))
        #expect(shrunk.width == 2048 && shrunk.height == 500)
        let small = ScreenCaptureTestSupport.image(width: 100, height: 50)
        #expect(AskScreenshotAttachments.shrink(small, longEdge: 2048) === small)
    }

    // MARK: Launcher

    private func fixture(_ lines: [String]) throws -> (AskTestFixture, StubRecognizer) {
        let fixture = try AskTestFixture()
        let recognizer = StubRecognizer(lines)
        fixture.model.screenshotTextRecognizer = recognizer
        return (fixture, recognizer)
    }

    @Test func recognizedTextOpensInTheLauncherAfterItsContext() async throws {
        let (fixture, recognizer) = try fixture(["Hello", "World"])
        defer { fixture.model.resetSession() }
        let model = fixture.model
        var shown: [@MainActor () -> Void] = []
        model.onShowLauncher = { prepared in
            model.resetLauncherForPresentation(preservingScreenshot: true)
            shown.append(prepared)
        }
        model.launcherDraft.text = "an unfinished question"

        model.handle(.recognizeText, image: image())
        #expect(shown.count == 1)
        #expect(model.plugins.keyword == nil, "Nothing changes before the launcher is ready")
        shown[0]()

        #expect(model.plugins.keyword?.pluginID == AskScreenshotTextPlugin.id)
        #expect(model.launcherDraft.text.isEmpty)
        try await fixture.wait { model.plugins.output != nil }
        #expect(model.plugins.output?.body == "Hello\nWorld")
        #expect(recognizer.calls == 1)
        #expect(model.launcherScreenshot?.source.fitsQuestion == true)

        // Using the result lets the screenshot go.
        model.finishPluginResult()
        #expect(model.launcherScreenshot == nil)
        #expect(model.plugins.keyword == nil)
    }

    @Test func ordinaryLauncherOpeningReleasesThePreviousScreenshot() throws {
        let (fixture, _) = try fixture(["old text"])
        defer { fixture.model.resetSession() }
        let model = fixture.model
        model.launcherScreenshot = model.makeLauncherScreenshot(image())
        let recognition = try #require(model.launcherScreenshot).source.recognition

        model.resetLauncherForPresentation()

        #expect(model.launcherScreenshot == nil)
        #expect(recognition.isCancelled)
    }

    @Test(arguments: [false, true])
    func interruptedRecognitionEndsLoadingAndRetryReadsTheSameImage(cancelled: Bool) async throws {
        let (fixture, recognizer) = try fixture(["Recovered text"])
        defer { fixture.model.resetSession() }
        let model = fixture.model
        let picture = image()
        model.launcherScreenshot = AskLauncherScreenshot(image: picture, source: .init(
            pixelSize: picture.pixelSize, fitsQuestion: true,
            recognition: Task {
                if cancelled { throw CancellationError() }
                throw ImageTilingError.unreadable
            }))
        model.showScreenshotText()

        try await fixture.wait { model.plugins.failure != nil }
        #expect(!model.plugins.isRunning)
        if cancelled { #expect(model.plugins.failure?.message == L("screenshot.text.interrupted")) }
        let action = try #require(model.plugins.failure?.action(for: .enter))
        #expect(action.kind == .screenshotFollowUp(.recognizeText))
        _ = model.performPluginAction(action)
        try await fixture.wait { model.plugins.output != nil }
        #expect(model.plugins.output?.body == "Recovered text")
        #expect(recognizer.calls == 1)
        #expect(model.launcherScreenshot?.image.image === picture.image)
    }

    @Test func realRecognitionReturnsTextToTheLauncher() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let data = ClipboardTestSupport.imageData(width: 1200, height: 240, text: "SCREENSHOT OCR 2026")
        let cgImage = try #require(NSBitmapImageRep(data: data)?.cgImage)
        fixture.model.screenshotTextRecognizer = TiledImageTextRecognizer(base: VisionImageTextRecognizer(
            worker: MediaWorker(timeout: 90, run: { request, cancelled in
                try ManagedProcess().runBlocking(request, isCancelled: cancelled)
            })))
        fixture.model.onShowLauncher = { prepared in
            fixture.model.resetLauncherForPresentation(preservingScreenshot: true)
            prepared()
        }
        fixture.model.handle(.recognizeText, image: .init(image: cgImage, scale: 1, isLongImage: false))
        let screenshot = try #require(fixture.model.launcherScreenshot)
        let recognized = try await screenshot.source.recognition.value
        #expect(recognized.string?.contains("SCREENSHOT OCR 2026") == true)
        try await fixture.wait { fixture.model.plugins.output != nil }
        #expect(fixture.model.plugins.output?.body.contains("SCREENSHOT OCR 2026") == true)
    }

    @Test func aStaleLauncherOpeningDoesNothing() throws {
        let (fixture, _) = try fixture(["one"])
        defer { fixture.model.resetSession() }
        let model = fixture.model
        var shown: [@MainActor () -> Void] = []
        model.onShowLauncher = { prepared in
            model.resetLauncherForPresentation(preservingScreenshot: true)
            shown.append(prepared)
        }
        model.handle(.recognizeText, image: image())
        model.handle(.recognizeText, image: image())
        shown[0]()
        #expect(model.plugins.keyword == nil, "The first screenshot was replaced")
        shown[1]()
        #expect(model.plugins.keyword?.pluginID == AskScreenshotTextPlugin.id)
        model.foldLauncherKeyword()
        #expect(model.launcherScreenshot == nil, "Closing the launcher lets it go")
    }

    @Test func translatingRunsTheTranslationKeywordOnTheText() async throws {
        let (fixture, _) = try fixture(["Bonjour"])
        defer { fixture.model.resetSession() }
        let model = fixture.model

        model.handle(.translate, image: image())

        try await fixture.wait { model.plugins.keyword?.pluginID == AskTranslatePlugin.id }
        #expect(model.launcherDraft.text == "Bonjour")
        #expect(model.plugins.keyword?.contains("fy") == true)
        model.plugins.deactivate()
    }

    @Test func theTabActionTranslates() throws {
        let (fixture, _) = try fixture([])
        defer { fixture.model.resetSession() }
        let model = fixture.model
        let action = AskPluginAction(kind: .translate("Hallo"), title: "", symbol: "", shortcut: .tab)
        #expect(model.performPluginAction(action) == .stay)
        #expect(model.plugins.keyword?.pluginID == AskTranslatePlugin.id)
        #expect(model.launcherDraft.text == "Hallo")
        model.plugins.deactivate()
    }

    @Test func nothingToTranslateLeavesTheEmptyCard() async throws {
        let (fixture, _) = try fixture([])
        defer { fixture.model.resetSession() }
        let model = fixture.model

        model.handle(.translate, image: image())

        try await fixture.wait { model.plugins.failure != nil }
        #expect(model.plugins.keyword?.pluginID == AskScreenshotTextPlugin.id)
        #expect(model.plugins.failure?.message == L("screenshot.text.empty"))
    }

    @Test func askingTheAIAttachesTheScreenshotInsteadOfTheScreen() async throws {
        let (fixture, _) = try fixture([])
        defer { fixture.model.resetSession() }
        let model = fixture.model
        model.launcherDraft.includeScreenshot = true
        model.launcherDraft.text = "old"

        model.handle(.askAI, image: image(width: 600, height: 5000))

        try await fixture.wait { model.launcherDraft.attachedImageCount > 0 }
        #expect(model.launcherDraft.attachedImageCount == 3)
        #expect(model.launcherDraft.includeScreenshot == false)
        #expect(model.launcherDraft.screenshot == nil)
        #expect(model.launcherDraft.text.isEmpty)
        #expect(model.plugins.keyword == nil)
        #expect(model.attachmentLoads.isEmpty)
    }

    @Test func aScreenshotTooLongForTheAIIsReadFirst() async throws {
        let (fixture, _) = try fixture(["a very long page"])
        defer { fixture.model.resetSession() }
        let model = fixture.model

        model.handle(.askAI, image: image(width: 600, height: 40000))

        try await fixture.wait { model.plugins.output != nil }
        #expect(model.launcherDraft.attachedImageCount == 0)
        #expect(model.plugins.keyword?.pluginID == AskScreenshotTextPlugin.id)
        #expect(model.commandFeedback == L("screenshot.ask.tooLong"))
        #expect(model.plugins.output?.askAIAction?.kind == .askAI(L("screenshot.text.askAI", "a very long page")))
    }

    @Test func commandReturnOnTheTextAsksAboutTheImage() async throws {
        let (fixture, _) = try fixture(["chart"])
        defer { fixture.model.resetSession() }
        let model = fixture.model
        #expect(model.performScreenshotFollowUp(.askAI) == .stay, "Nothing waiting")

        model.handle(.recognizeText, image: image())
        try await fixture.wait { model.plugins.output != nil }
        let ask = try #require(model.plugins.output?.askAIAction)
        #expect(model.performPluginAction(ask) == .stay)

        try await fixture.wait { model.launcherDraft.attachedImageCount == 1 }
        #expect(model.plugins.keyword == nil)
    }

    @Test func otherFollowUpsOnTheWaitingScreenshot() async throws {
        let (fixture, _) = try fixture(["Guten Tag"])
        defer { fixture.model.resetSession() }
        let model = fixture.model
        model.handle(.recognizeText, image: image())
        try await fixture.wait { model.plugins.output != nil }

        model.plugins.deactivate()
        #expect(model.performScreenshotFollowUp(.recognizeText) == .stay)
        #expect(model.plugins.keyword?.pluginID == AskScreenshotTextPlugin.id)
        #expect(model.performScreenshotFollowUp(.translate) == .stay)
        try await fixture.wait { model.plugins.keyword?.pluginID == AskTranslatePlugin.id }
        model.plugins.deactivate()
    }

    @Test func anUnreadableScreenshotSaysSo() throws {
        let (fixture, _) = try fixture([])
        defer { fixture.model.resetSession() }
        let model = fixture.model
        model.applyScreenshotAttachments(.failure(.unreadable), image: image())
        #expect(model.launcherAttachmentNotice
            == AskAttachmentError.unreadable(L("screenshot.ask.attachmentName")).message)
    }

    @Test func theCaptureActionPassesItsFollowUp() async throws {
        let (fixture, _) = try fixture([])
        defer { fixture.model.resetSession() }
        let model = fixture.model
        var started: [(ScreenshotMode, ScreenshotFollowUp?)] = []
        model.onStartScreenshot = { started.append(($0, $1)) }
        let action = AskPluginAction(kind: .capture(mode: .region, followUp: .recognizeText), title: "", symbol: "")
        #expect(model.performPluginAction(action) == .close)
        try await fixture.wait { !started.isEmpty }
        #expect(started.first?.0 == .region && started.first?.1 == .recognizeText)
    }
}
