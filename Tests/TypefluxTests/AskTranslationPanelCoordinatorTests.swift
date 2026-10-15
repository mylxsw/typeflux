import AppKit
import Testing
@testable import Typeflux

@MainActor
final class TranslationPanelInjector: TextInjector {
    var snapshot = TextSelectionSnapshot(processID: 42, selectedText: "Selected sentence.", isEditable: true,
                                         isFocusedTarget: true, replacementSafety: .verifiedPaste,
                                         selectionBounds: CGRect(x: 100, y: 200, width: 100, height: 20))
    var captures: [SelectionCaptureIntent] = []
    var delivered: [String] = []
    var replaced = false
    var deliveryResult: TextDeliveryResult = .delivered(.paste)
    var deliveryError: Error?
    var onCapture: (() async -> Void)?
    func makeReadOnlySelectionRequest() -> ReadOnlySelectionRequest {
        .init(processID: 42)
    }

    func readOnlySelectionSnapshot(for _: ReadOnlySelectionRequest) async -> TextSelectionSnapshot {
        snapshot
    }

    func selectionSnapshot(for intent: SelectionCaptureIntent) async -> TextSelectionSnapshot {
        captures.append(intent)
        await onCapture?()
        return snapshot
    }

    func currentInputTextSnapshot() async -> CurrentInputTextSnapshot {
        .init()
    }

    func currentInputText() async -> String? {
        nil
    }

    func deliver(text: String, to destination: TextDeliveryDestination) async throws -> TextDeliveryResult {
        if let deliveryError {
            throw deliveryError
        }
        delivered.append(text)
        if case .selection = destination {
            replaced = true
        }
        return deliveryResult
    }
}

struct TranslationPanelRecognizer: ImageTextRecognizing {
    var text: String? = "Recognized screenshot sentence."
    var fails = false
    var delay: Duration = .zero
    func recognizeText(in _: ImageTextSource) async throws -> RecognizedText {
        if delay != .zero {
            try await Task.sleep(for: delay)
        }
        if fails {
            throw URLError(.cannotDecodeContentData)
        }
        return RecognizedText(lines: text.map { [.init(text: $0, confidence: 1, boundingBox: .zero)] } ?? [])
    }
}

@MainActor
func translationPanelImage() -> ScreenshotFollowUpImage {
    let image = NSImage(size: NSSize(width: 220, height: 60))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 220, height: 60).fill()
    ("The best way to predict the future\nis to invent it." as NSString).draw(at: NSPoint(x: 8, y: 16),
                                                                              withAttributes: [
                                                                                  .font: NSFont.systemFont(ofSize: 12),
                                                                                  .foregroundColor: NSColor.black
                                                                              ])
    image.unlockFocus()
    return .init(image: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!, scale: 1, isLongImage: false)
}

@Suite("Translation panel entry points", .exclusiveUIState)
@MainActor
struct AskTranslationPanelCoordinatorTests {
    private func coordinator(_ fixture: TranslationPanelFixture, injector: TranslationPanelInjector,
                             recognizer: TranslationPanelRecognizer = .init()) -> AskTranslationPanelCoordinator {
        _ = NSApplication.shared
        let controller = AskTranslationPanelController(model: fixture.model)
        let coordinator = AskTranslationPanelCoordinator(model: fixture.model, controller: controller,
                                                         injector: injector, recognizer: recognizer)
        coordinator.frontmost = { 42 }
        coordinator.activate = { _ in }
        coordinator.restoreFocus = {}
        return coordinator
    }

    @Test func `selection panel appears before capture finishes and keeps source focus`() async throws {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let injector = TranslationPanelInjector()
        injector.onCapture = { try? await Task.sleep(for: .milliseconds(200)) }
        let entry = coordinator(fixture, injector: injector)
        entry.controller.prewarm()
        #expect(!entry.controller.isPresented)

        entry.openSelection()
        let window = try #require(entry.controller.presentedWindow)
        #expect(window.isVisible && !window.isKeyWindow)
        #expect(fixture.ai.requests.isEmpty)

        await entry.waitForEntry()
        await fixture.model.waitForTranslation()
        #expect(fixture.model.source == .selection && fixture.model.text == "Selected sentence.")
        #expect(window.isKeyWindow && fixture.ai.requests.count == 1)
    }

    @Test func `selection capture does not replace text typed while the panel is open`() async {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let injector = TranslationPanelInjector()
        injector.onCapture = { try? await Task.sleep(for: .milliseconds(100)) }
        let entry = coordinator(fixture, injector: injector)
        entry.openSelection()
        fixture.model.text = "A new draft."

        await entry.waitForEntry()
        #expect(entry.controller.isPresented && fixture.model.text == "A new draft.")
        #expect(fixture.ai.requests.isEmpty)
    }

    @Test func `translation shortcut toggles the panel and cancels pending capture`() async {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let injector = TranslationPanelInjector()
        injector.onCapture = { try? await Task.sleep(for: .milliseconds(80)) }
        let entry = coordinator(fixture, injector: injector)

        entry.toggleSelection()
        #expect(entry.controller.isPresented)
        entry.toggleSelection()
        #expect(!entry.controller.isPresented)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fixture.ai.requests.isEmpty)

        entry.toggleSelection()
        await entry.waitForEntry()
        await fixture.model.waitForTranslation()
        #expect(entry.controller.isPresented && fixture.ai.requests.count == 1)
        fixture.model.pinned = true
        entry.toggleSelection()
        #expect(!entry.controller.isPresented && !fixture.model.running)
    }

    @Test func `input waits for return and selection sends immediately on every shortcut`() async {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let injector = TranslationPanelInjector()
        let entry = coordinator(fixture, injector: injector)
        entry.openInput()
        fixture.model.text = "Input sentence."
        #expect(entry.controller.isPresented && fixture.ai.requests.isEmpty && injector.captures.isEmpty)
        entry.openInput()
        #expect(fixture.model.text == "Input sentence.")
        fixture.model.dismiss()
        entry.openSelection()
        await entry.waitForEntry()
        await fixture.model.waitForTranslation()
        #expect(fixture.model.source == .selection && fixture.model.text == "Selected sentence.")
        #expect(fixture.ai.requests.count == 1 && injector.captures == [.explicitSelectionAction])
        entry.openSelection()
        await entry.waitForEntry()
        await fixture.model.waitForTranslation()
        #expect(injector.captures.count == 2 && fixture.ai.requests.count == 2)
        fixture.model.pinned = true
        entry.insert("Replacement")
        await entry.waitForDelivery()
        #expect(injector.delivered == ["Replacement"] && injector.replaced && entry.controller.isPresented)
        fixture.model.dismiss()
        injector.snapshot.selectedText = nil
        entry.openSelection()
        await entry.waitForEntry()
        #expect(fixture.model.source == .input && fixture.ai.requests.count == 2)
    }

    @Test func `screenshots recognize locally then translate or show recoverable errors`() async {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let injector = TranslationPanelInjector()
        for (recognizer, expected) in [(TranslationPanelRecognizer(), 1),
                                       (TranslationPanelRecognizer(text: nil), 0),
                                       (TranslationPanelRecognizer(fails: true), 0)] {
            let entry = coordinator(fixture, injector: injector, recognizer: recognizer)
            let before = fixture.ai.requests.count
            entry.openScreenshot(translationPanelImage())
            #expect(fixture.model.source == .screenshot && fixture.model.screenshot != nil)
            await entry.waitForEntry()
            await fixture.model.waitForTranslation()
            #expect(fixture.ai.requests.count == before + expected)
            #expect((fixture.model.notice != nil) == (expected == 0))
            if expected == 1 {
                #expect(fixture.model.screenshotLines == 1)
            }
            fixture.model.dismiss()
        }
    }

    @Test func `pending selection and OCR do not overwrite A newer entry or user edits`() async {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let injector = TranslationPanelInjector()
        let entry = coordinator(fixture, injector: injector, recognizer: .init(delay: .milliseconds(40)))
        injector.onCapture = { try? await Task.sleep(for: .milliseconds(40)) }
        entry.openSelection()
        entry.openInput()
        await entry.waitForEntry()
        #expect(fixture.model.source == .input)
        fixture.model.dismiss()
        entry.openScreenshot(translationPanelImage())
        fixture.model.text = "The user typed this."
        await entry.waitForEntry()
        #expect(fixture.model.text == "The user typed this." && fixture.ai.requests.isEmpty)
        entry.openScreenshot(translationPanelImage())
        fixture.model.dismiss()
        await entry.waitForEntry()
        #expect(!entry.controller.isPresented && fixture.ai.requests.isEmpty)
    }

    @Test func `insertion checks the source and selection and copies when delivery fails`() async {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let injector = TranslationPanelInjector()
        let entry = coordinator(fixture, injector: injector)
        entry.openInput()
        entry.insert("Inserted")
        entry.insert("Duplicate")
        await entry.waitForDelivery()
        #expect(injector.delivered == ["Inserted"] && !injector.replaced)
        entry.insert(" ")
        #expect(injector.delivered.count == 1)
        entry.openInput()
        entry.frontmost = { 99 }
        entry.insert("Wrong app")
        await entry.waitForDelivery()
        #expect(fixture.copied.last == "Wrong app" && fixture.model.notice != nil)
        fixture.model.dismiss()
        entry.frontmost = { nil }
        entry.openInput()
        entry.insert("No app")
        await entry.waitForDelivery()
        #expect(fixture.copied.last == "No app")
        fixture.model.dismiss()
        entry.frontmost = { 42 }
        entry.openSelection()
        await entry.waitForEntry()
        await fixture.model.waitForTranslation()
        injector.deliveryResult = .unconfirmed(.paste)
        entry.insert("Unconfirmed")
        await entry.waitForDelivery()
        #expect(fixture.copied.last == "Unconfirmed")
        fixture.model.dismiss()
        injector.snapshot.replacementSafety = .resultOnly
        entry.openSelection()
        await entry.waitForEntry()
        await fixture.model.waitForTranslation()
        entry.insert("Read-only")
        await entry.waitForDelivery()
        #expect(fixture.copied.last == "Read-only")
    }

    @Test func `launcher moves completed and private results without new calls`() async {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let entry = coordinator(fixture, injector: TranslationPanelInjector())
        let session = AskPluginSession(plugins: [fixture.model.plugin]) { AskTranslatePlugin.keywords }
        session.debounce = .zero
        session.enter(AskTranslatePlugin.keywords[0])
        session.update(text: "The launcher sentence.", selection: nil, language: .english)
        for _ in 0 ..< 200 where session.output == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(session.output?.translation?.submitted == false)
        let before = fixture.ai.requests.count
        var closed = 0
        #expect(entry.moveFromLauncher(session, closeLauncher: { closed += 1 }))
        #expect(closed == 1 && fixture.model.pinned && fixture.model.source == .launcher)
        #expect(fixture.ai.requests.count == before)
        fixture.model.dismiss()
        session.deactivate()
        #expect(entry.moveFromLauncher(session, closeLauncher: {}) == false)
        let result = AskPluginOutput(
            body: "Meaning",
            original: "The selected sentence.",
            meta: [],
            source: "AI",
            actions: [],
            translation: .init(results: [.init(service: .ai(), name: "AI", state: .done("Meaning"))], source: "en",
                               target: "fr", interface: .english, submitted: true,
                               isLookup: false, replacesSelection: true)
        )
        entry.moveFromLauncher(result)
        let injector = TranslationPanelInjector()
        // A moved selection is recaptured explicitly before replacement.
        let second = AskTranslationPanelCoordinator(model: fixture.model, controller: entry.controller,
                                                    injector: injector, recognizer: TranslationPanelRecognizer())
        second.frontmost = { 42 }; second.activate = { _ in }; second.restoreFocus = {}
        second.moveFromLauncher(result)
        injector.snapshot.selectedText = result.original
        second.insert("Meaning")
        await second.waitForDelivery()
        #expect(injector.captures == [.explicitSelectionAction] && injector.replaced)
    }
}

extension AskTranslationPanelCoordinatorTests {
    @Test func `a completed submitted launcher run moves its output without calling providers again`() async {
        _ = NSApplication.shared
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let controller = AskTranslationPanelController(model: fixture.model)
        let entry = AskTranslationPanelCoordinator(model: fixture.model, controller: controller,
                                                   injector: TranslationPanelInjector(),
                                                   recognizer: TranslationPanelRecognizer())
        let session = AskPluginSession(plugins: [fixture.model.plugin]) { AskTranslatePlugin.keywords }
        session.debounce = .zero
        session.enter(AskTranslatePlugin.keywords[0])
        session.update(text: "A submitted launcher sentence.", selection: nil, language: .english, runWhenPlanned: true)
        for _ in 0 ..< 200 where session.output?.translation?.submitted != true {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let before = fixture.ai.requests.count
        #expect(session.output?.translation?.submitted == true)
        #expect(entry.moveFromLauncher(session, closeLauncher: {}))
        #expect(fixture.model.output?.original == "A submitted launcher sentence.")
        #expect(fixture.model.pinned && !fixture.model.isDirty && fixture.ai.requests.count == before)
        let deviceCalls = fixture.device.requests.count
        fixture.model.moveSelection(1)
        fixture.model.shortcut(.commandR)
        await fixture.model.waitForTranslation()
        #expect(fixture.device.requests.count == deviceCalls && fixture.ai.requests.count == before + 1)
        #expect(fixture.model.stack.results.count == 2)
        session.deactivate()
    }
}

extension AskScreenshotFollowUpTests {
    @Test func `screenshot translation routes to the panel without launcher OCR`() throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let model = fixture.model
        var images: [ScreenshotFollowUpImage] = []
        var opens = 0
        model.onShowLauncher = { then in opens += 1; then() }
        model.onTranslateScreenshot = { images.append($0) }
        model.screenshotTextRecognizer = TranslationPanelRecognizer()
        let image = translationPanelImage()
        model.handle(.translate, image: image)
        #expect(images.count == 1 && opens == 0 && model.launcherScreenshot == nil)
        model.launcherScreenshot = model.makeLauncherScreenshot(image)
        #expect(model.performScreenshotFollowUp(.translate) == .close)
        #expect(images.count == 2)
        model.releaseLauncherScreenshot()
    }
}

extension AskTranslationPanelCoordinatorTests {
    @Test func `private preview continues after moving and waits for return before calling AI`() async {
        _ = NSApplication.shared
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        fixture.device.delay = .milliseconds(80)
        let controller = AskTranslationPanelController(model: fixture.model)
        let entry = AskTranslationPanelCoordinator(model: fixture.model, controller: controller,
                                                   injector: TranslationPanelInjector(),
                                                   recognizer: TranslationPanelRecognizer())
        var plugin = fixture.model.plugin
        plugin.fanout = AskTranslationFanout()
        let session = AskPluginSession(plugins: [plugin]) { AskTranslatePlugin.keywords }
        session.debounce = .zero
        session.enter(AskTranslatePlugin.keywords[0])
        session.update(text: "The private launcher sentence.", selection: nil, language: .english)
        for _ in 0 ..< 200 where !session.isRunning {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(entry.moveFromLauncher(session, closeLauncher: { session.deactivate() }))
        for _ in 0 ..< 200 where fixture.model.running {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(fixture.model.output?.translation?.submitted == false)
        #expect(fixture.model.output?.translation?.results.first?.completedText == "Device answer")
        #expect(fixture.ai.requests.isEmpty)
        fixture.model.submit()
        await fixture.model.waitForTranslation()
        #expect(fixture.ai.requests.count == 1)
    }
}
