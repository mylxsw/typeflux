import CoreGraphics
import Foundation
import Testing
@testable import Typeflux

@Suite("Screenshot text organization", .exclusiveUIState)
@MainActor
struct AskScreenshotTextOrganizationTests {
    private let raw = "3.设计稿\n给出可视化的界面设计稿。\n•技术架构：Swift\n•活跃用户：128,430"
    private let markdown = "## 3. 设计稿\n\n给出可视化的界面设计稿。\n\n- 技术架构：Swift\n- 活跃用户：128,430"

    private func source(_ text: String, fits: Bool = true) -> AskScreenshotTextSource {
        let recognized = RecognizedText(lines: text.components(separatedBy: "\n").map {
            RecognizedText.Line(text: $0, confidence: 1, boundingBox: .zero)
        })
        return AskScreenshotTextSource(pixelSize: CGSize(width: 2008, height: 1134), fitsQuestion: fits,
                                       recognition: Task { recognized })
    }

    private func request(organizing source: AskScreenshotTextSource? = nil) -> AskPluginRequest {
        AskPluginRequest(text: "unrelated editor text", origin: .argument,
                         keyword: AskScreenshotTextPlugin.keywords[0],
                         options: source.map { [AskScreenshotTextPlugin.organizeOption: $0.id.uuidString] } ?? [:],
                         interfaceLanguage: .english, selection: "unrelated selection")
    }

    @Test func rawRecognitionNeverCallsAIAndAlwaysOffersOrganization() async throws {
        let generator = AskTestTextGenerator()
        let shown = source(raw)
        let plugin = AskScreenshotTextPlugin(screenshot: { shown }, generator: generator)
        let input = request()
        let output = try await plugin.run(input, plan: plugin.plan(input)) { _ in }
        #expect(generator.prompts.isEmpty)
        #expect(!output.markdown && !output.sourceIsAI)
        #expect(output.actions.contains(AskScreenshotTextPlugin.organizeAction(shown.id)))
        let noModel = AskScreenshotTextPlugin(screenshot: { shown })
        let local = try await noModel.run(input, plan: noModel.plan(input)) { _ in }
        #expect(local.actions.contains(AskScreenshotTextPlugin.organizeAction(shown.id)))
    }

    @Test func organizationWaitsForExplicitSubmissionAndIsBoundToOneCapture() async {
        let shown = source(raw)
        let plugin = AskScreenshotTextPlugin(screenshot: { shown })
        let plan = await plugin.plan(request(organizing: shown))
        #expect(plan.mode == .onSubmit)
        #expect(plan.title == L("screenshot.text.organize"))
        #expect(plan.values[AskScreenshotTextPlugin.organizeOption] == shown.id.uuidString)
        #expect(await plugin.plan(request(organizing: source("another"))).mode == .live)
        #expect(await AskScreenshotTextPlugin().plan(request(organizing: shown))
            .action(for: .enter)?.kind == .capture(mode: .region, followUp: .recognizeText))
    }

    @Test(arguments: [true, false])
    func organizedMarkdownStreamsAndAllExportsUseTheResult(fits: Bool) async throws {
        let shown = source(raw, fits: fits)
        let generator = AskTestTextGenerator()
        generator.pieces = [" \n", markdown, "\n"]
        let plugin = AskScreenshotTextPlugin(screenshot: { shown }, generator: generator,
                                            modelName: { "test-model" }, savesNotes: true)
        let input = request(organizing: shown)
        var partials: [AskPluginOutput] = []
        let result = try await plugin.run(input, plan: plugin.plan(input)) { partials.append($0) }
        #expect(generator.prompts.count == 1)
        #expect(generator.prompts[0].user == raw, "Only this capture's text is sent")
        #expect(generator.prompts[0].system == AskScreenshotTextPlugin.organizationPrompt)
        #expect(partials.map(\.body) == [" \n", " \n" + markdown, " \n" + markdown + "\n"])
        #expect(partials.allSatisfy { $0.markdown && $0.sourceIsAI && $0.original == raw })
        #expect(result.body == markdown && result.original == raw)
        #expect(result.markdown && result.sourceIsAI)
        #expect(result.source == AskPluginRegistry.sourceLabel("test-model"))
        #expect(result.action(for: .enter)?.kind == .copy(markdown))
        #expect(result.action(for: .commandC)?.kind == .copy(markdown))
        #expect(result.action(for: .optionEnter)?.kind == .writeBack(markdown))
        #expect(result.action(for: .tab)?.kind == .translate(markdown))
        #expect(result.action(for: .commandR)?.kind == .capture(mode: .region, followUp: .recognizeText))
        #expect(result.actions.contains(AskScreenshotTextPlugin.originalAction))
        #expect(result.askAIAction?.kind == (fits ? .screenshotFollowUp(.askAI)
            : .askAI(L("screenshot.text.askAI", markdown))))
        let note = try #require(result.noteDraft)
        #expect(note.body == markdown && note.input == raw && note.model == "test-model")
        #expect(note.command == L("screenshot.text.organize") && note.keyword == "ocr")
        #expect(result.starred == false)
    }

    @Test func notesWithoutAModelNameOmitTheNameAndWithoutAStoreOfferNoSave() async throws {
        let shown = source(raw)
        let generator = AskTestTextGenerator()
        let plugin = AskScreenshotTextPlugin(screenshot: { shown }, generator: generator, savesNotes: true)
        let input = request(organizing: shown)
        let result = try await plugin.run(input, plan: plugin.plan(input)) { _ in }
        #expect(result.noteDraft?.model == nil)
        let noNotes = AskScreenshotTextPlugin(screenshot: { shown }, generator: generator)
        let unsaved = try await noNotes.run(input, plan: noNotes.plan(input)) { _ in }
        #expect(unsaved.noteDraft == nil && unsaved.starred == nil)
    }

    @Test func failuresOfferTheOriginalAndRecaptureAndPreserveSignIn() async throws {
        let shown = source(raw)
        let generator = AskTestTextGenerator()
        let input = request(organizing: shown)
        for scenario in ["no-model", "empty", "offline", "sign-in"] {
            generator.pieces = scenario == "empty" ? [" ", "\n"] : []
            generator.failure = scenario == "offline" ? URLError(.notConnectedToInternet)
                : scenario == "sign-in" ? TypefluxCloudLLMError.notLoggedIn : nil
            let plugin = AskScreenshotTextPlugin(screenshot: { shown },
                                                generator: scenario == "no-model" ? nil : generator)
            do {
                _ = try await plugin.run(input, plan: plugin.plan(input)) { _ in }
                Issue.record("Expected failure: \(scenario)")
            } catch let failure as AskPluginFailure {
                #expect(failure.actions.contains(AskScreenshotTextPlugin.originalAction))
                #expect(failure.action(for: .commandR)?.kind == .capture(mode: .region, followUp: .recognizeText))
                #expect(failure.retry == (scenario == "empty" || scenario == "offline"))
                if scenario == "sign-in" { #expect(failure.action(for: .enter)?.kind == .signIn) }
                if scenario == "empty" { #expect(failure.message == L("screenshot.text.organize.empty")) }
            }
        }
    }

    @Test func emptyOCRDoesNotCallTheModel() async throws {
        let shown = source(" \n ")
        let generator = AskTestTextGenerator()
        let plugin = AskScreenshotTextPlugin(screenshot: { shown }, generator: generator)
        let input = request(organizing: shown)
        do {
            _ = try await plugin.run(input, plan: plugin.plan(input)) { _ in }
            Issue.record("Expected empty OCR")
        } catch let failure as AskPluginFailure {
            #expect(failure.message == L("screenshot.text.empty") && !failure.retry)
        }
        #expect(generator.prompts.isEmpty)
    }

    @Test func cancellationIsNotShownAsAnOrganizationFailure() async throws {
        let shown = source(raw)
        let generator = AskTestTextGenerator()
        generator.failure = CancellationError()
        let plugin = AskScreenshotTextPlugin(screenshot: { shown }, generator: generator)
        let input = request(organizing: shown)
        await #expect(throws: CancellationError.self) {
            try await plugin.run(input, plan: plugin.plan(input)) { _ in }
        }
    }

    @Test func replacingTheCaptureWhileStreamingDiscardsTheResult() async throws {
        let shown = source(raw)
        var current: AskScreenshotTextSource? = shown
        let generator = AskTestTextGenerator()
        let plugin = AskScreenshotTextPlugin(screenshot: { current }, generator: generator)
        let input = request(organizing: shown)
        let plan = await plugin.plan(input)
        await #expect(throws: CancellationError.self) {
            try await plugin.run(input, plan: plan) { _ in current = nil }
        }
    }

    @Test func launcherActionOrganizesRestoresRetriesAndRecaptureResetsAI() async throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        defer { model.resetSession() }
        let generator = AskTestTextGenerator()
        generator.pieces = [markdown]
        model.promptAI = generator
        model.notes = makeTestNotes()
        model.launcherScreenshot = AskLauncherScreenshot(
            image: ScreenshotFollowUpImage(image: ScreenCaptureTestSupport.image(width: 400, height: 200),
                                           scale: 2, isLongImage: false), source: source(raw))
        model.showScreenshotText()
        try await fixture.wait { model.plugins.output != nil }
        #expect(generator.prompts.isEmpty)
        let action = try #require(model.plugins.output?.actions.first {
            if case .rerun = $0.kind { return true }; return false
        })
        #expect(model.performPluginAction(action) == .stay)
        try await fixture.wait { model.plugins.output?.markdown == true }
        #expect(model.plugins.output?.body == markdown)
        let save = try #require(model.plugins.output?.action(for: .commandS))
        #expect(model.performPluginAction(save) == .stay)
        await model.notebookTask?.value
        #expect(try await model.notes?.list(AskNoteQuery()).first?.body == markdown)
        #expect(model.performPluginAction(AskScreenshotTextPlugin.originalAction) == .stay)
        try await fixture.wait { model.plugins.output?.body == raw }
        #expect(model.plugins.output?.markdown == false && generator.prompts.count == 1)

        generator.pieces = []
        #expect(model.performPluginAction(action) == .stay)
        try await fixture.wait { model.plugins.failure != nil }
        generator.pieces = [markdown]
        #expect(model.plugins.run())
        try await fixture.wait { model.plugins.output?.markdown == true }

        model.launcherScreenshot = AskLauncherScreenshot(
            image: ScreenshotFollowUpImage(image: ScreenCaptureTestSupport.image(width: 100, height: 100),
                                           scale: 2, isLongImage: false), source: source("new capture"))
        model.showScreenshotText()
        try await fixture.wait { model.plugins.output?.body == "new capture" }
        #expect(model.plugins.output?.markdown == false && generator.prompts.count == 3)
    }

    @Test func leavingKeywordModeDuringOrganizationCancelsWithoutReplacingTheNextResult() async throws {
        let shown = source(raw)
        let generator = AskTestTextGenerator()
        generator.delay = .milliseconds(200)
        let plugin = AskScreenshotTextPlugin(screenshot: { shown }, generator: generator)
        let session = AskPluginSession(plugins: [plugin]) { AskScreenshotTextPlugin.keywords }
        defer { session.deactivate() }
        session.enter(AskScreenshotTextPlugin.keywords[0])
        session.update(text: "", selection: nil, language: .english)
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        try await fixture.wait { session.output != nil }
        session.rerun(with: [AskScreenshotTextPlugin.organizeOption: shown.id.uuidString],
                      selection: nil, text: "", language: .english)
        try await fixture.wait { !generator.prompts.isEmpty }
        session.deactivate()
        session.enter(AskScreenshotTextPlugin.keywords[0])
        session.update(text: "", selection: nil, language: .english)
        try await fixture.wait { session.output?.body == raw }
        try await Task.sleep(for: .milliseconds(250))
        #expect(session.output?.body == raw && session.output?.markdown == false && session.failure == nil)
    }
}
