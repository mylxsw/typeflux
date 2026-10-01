import AppKit
import Testing
@testable import Typeflux

@MainActor
private final class ContextTextInjector: TextInjector {
    var intents: [SelectionCaptureIntent] = []
    var text: String? = "Selected message"
    func selectionSnapshot(for intent: SelectionCaptureIntent) async -> TextSelectionSnapshot {
        intents.append(intent)
        return TextSelectionSnapshot(selectedText: text)
    }
    func currentInputTextSnapshot() async -> CurrentInputTextSnapshot { .init() }
    func currentInputText() async -> String? { nil }
    func deliver(text: String, to destination: TextDeliveryDestination) async throws -> TextDeliveryResult {
        Issue.record("Context capture must never deliver text")
        return .notApplied(.paste)
    }
}

@Suite("Ask context selection")
@MainActor
struct AskContextCaptureTests {
    @Test func launcherCapturesReadOnlySelectionWithoutScreenshot() async {
        let injector = ContextTextInjector()
        let capture = AskContextCapture(injector: injector, accessibilityTrusted: { true }, captureScreenshot: { _ in
            Issue.record("Screenshot was not requested"); return "image"
        })
        let context = await capture.capture(includeScreenshot: false)
        #expect(injector.intents == [.readOnlyContext])
        #expect(context.selection == "Selected message")
        #expect(context.screenshot == nil)
    }

    @Test func screenshotRefreshDoesNotReadSelectionEvenWithAccessibilityPermission() async {
        let injector = ContextTextInjector()
        let capture = AskContextCapture(injector: injector, accessibilityTrusted: { true }, captureScreenshot: { _ in "image" })
        let context = await capture.capture(includeScreenshot: true, includeSelection: false)
        #expect(injector.intents.isEmpty)
        #expect(context.selection == nil)
        #expect(context.screenshot == "image")
    }

    @Test func missingAccessibilityPermissionStillAllowsScreenshot() async {
        let injector = ContextTextInjector()
        let capture = AskContextCapture(injector: injector, accessibilityTrusted: { false }, captureScreenshot: { _ in "image" })
        let context = await capture.capture(includeScreenshot: true)
        #expect(injector.intents.isEmpty)
        #expect(context.selection == nil)
        #expect(context.screenshot == "image")
    }

    @Test func screenshotFailurePreservesSelection() async {
        let injector = ContextTextInjector()
        let capture = AskContextCapture(injector: injector, accessibilityTrusted: { true }, captureScreenshot: { _ in
            throw AskLocalError.message("Capture unavailable")
        })
        let context = await capture.capture(includeScreenshot: true)
        #expect(context.selection == "Selected message")
        #expect(context.warning == "Capture unavailable")
    }

    @Test func emptySelectionStaysAbsent() async {
        let injector = ContextTextInjector()
        injector.text = nil
        let capture = AskContextCapture(injector: injector, accessibilityTrusted: { true })
        let context = await capture.capture(includeScreenshot: false)
        #expect(context.selection == nil)
    }

    @Test func modelRefreshPreservesSelectionAndRequestsScreenshotOnly() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        await fixture.model.prepareLauncher()
        #expect(fixture.capture.selectionRequests == [true])
        let selection = fixture.model.launcherDraft.selection
        await fixture.model.refreshScreenshot(launcher: true)
        #expect(fixture.capture.selectionRequests == [true, false])
        #expect(fixture.model.launcherDraft.selection == selection)
    }
}
