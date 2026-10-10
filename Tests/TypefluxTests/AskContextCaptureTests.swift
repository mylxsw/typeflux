import AppKit
import Testing
@testable import Typeflux

@MainActor
final class ContextTextInjector: TextInjector {
    var requests: [ReadOnlySelectionRequest] = []
    var source = ReadOnlySelectionRequest(processID: 42, processName: "Source app", bundleIdentifier: "test.source")
    var onRead: (() async -> Void)?
    func makeReadOnlySelectionRequest() -> ReadOnlySelectionRequest { source }
    func readOnlySelectionSnapshot(for request: ReadOnlySelectionRequest) async -> TextSelectionSnapshot {
        requests.append(request)
        await onRead?()
        return TextSelectionSnapshot(selectedText: text, source: text == nil ? "no-selection-found" : "accessibility-context")
    }
    var text: String? = "Selected message"
    func selectionSnapshot(for intent: SelectionCaptureIntent) async -> TextSelectionSnapshot {
        Issue.record("Ask must use a pinned request instead of the current application")
        return TextSelectionSnapshot(selectedText: text)
    }
    func currentInputTextSnapshot() async -> CurrentInputTextSnapshot { .init() }
    func currentInputText() async -> String? { nil }
    func deliver(text: String, to destination: TextDeliveryDestination) async throws -> TextDeliveryResult {
        Issue.record("Context capture must never deliver text")
        return .notApplied(.paste)
    }
}

@Suite("Ask context selection", .exclusiveUIState)
@MainActor
struct AskContextCaptureTests {
    @Test func systemDialogUsesPreviousAppIdentityWithoutReadingItsSelection() async {
        let injector = ContextTextInjector()
        injector.source = .init(processID: 99, processName: "UserNotificationCenter")
        let tracker = AskSourceApplicationTracker(observeWorkspace: false, isRunning: { _ in true })
        tracker.record(.init(processID: 42, processName: "Safari", bundleIdentifier: "com.apple.Safari"), regular: true)
        let capture = AskContextCapture(injector: injector, permission: FakeScreenCapturePermission(granted: true), accessibilityTrusted: { true }, frontmostProcessID: { 42 },
                                       sourceTracker: tracker)
        let context = await capture.capture(includeScreenshot: false)
        #expect(context.source == "Safari" && context.sourceBundleID == "com.apple.Safari")
        #expect(context.selection == nil && context.selectionStatus == "system-ui-fallback")
        #expect(injector.requests.isEmpty)
    }

    @Test func launcherCapturesReadOnlySelectionWithoutScreenshot() async {
        let injector = ContextTextInjector()
        let capture = AskContextCapture(injector: injector, permission: FakeScreenCapturePermission(granted: true), accessibilityTrusted: { true }, frontmostProcessID: { 42 }, captureScreenshot: { _ in
            Issue.record("Screenshot was not requested"); return "image"
        })
        let context = await capture.capture(includeScreenshot: false)
        #expect(injector.requests.map(\.id) == [injector.source.id])
        #expect(context.selection == "Selected message")
        #expect(context.screenshot == nil)
    }

    @Test func screenshotRefreshDoesNotReadSelectionEvenWithAccessibilityPermission() async {
        let injector = ContextTextInjector()
        let capture = AskContextCapture(injector: injector, permission: FakeScreenCapturePermission(granted: true), accessibilityTrusted: { true }, frontmostProcessID: { 42 }, captureScreenshot: { _ in "image" })
        let context = await capture.capture(includeScreenshot: true, includeSelection: false)
        #expect(injector.requests.isEmpty)
        #expect(context.selection == nil)
        #expect(context.screenshot == "image")
    }

    @Test func missingAccessibilityPermissionStillAllowsScreenshot() async {
        let injector = ContextTextInjector()
        let capture = AskContextCapture(injector: injector, permission: FakeScreenCapturePermission(granted: true), accessibilityTrusted: { false }, frontmostProcessID: { 42 }, captureScreenshot: { _ in "image" })
        let context = await capture.capture(includeScreenshot: true)
        #expect(injector.requests.isEmpty)
        #expect(context.selection == nil)
        #expect(context.screenshot == "image")
    }

    @Test func screenshotFailurePreservesSelection() async {
        let injector = ContextTextInjector()
        let capture = AskContextCapture(injector: injector, permission: FakeScreenCapturePermission(granted: true), accessibilityTrusted: { true }, frontmostProcessID: { 42 }, captureScreenshot: { _ in
            throw AskLocalError.message("Capture unavailable")
        })
        let context = await capture.capture(includeScreenshot: true)
        #expect(context.selection == "Selected message")
        #expect(context.warning == "Capture unavailable")
    }

    @Test func emptySelectionStaysAbsent() async {
        let injector = ContextTextInjector()
        injector.text = nil
        let capture = AskContextCapture(injector: injector, permission: FakeScreenCapturePermission(granted: true), accessibilityTrusted: { true }, frontmostProcessID: { 42 })
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

    @Test func changingSourceBeforeCaptureDoesNotReadTheNewApplication() async {
        let injector = ContextTextInjector()
        let capture = AskContextCapture(injector: injector, permission: FakeScreenCapturePermission(granted: true), accessibilityTrusted: { true }, frontmostProcessID: { 99 },
                                       captureScreenshot: { _ in Issue.record("Stale source must not capture"); return "image" })
        let request = capture.makeSelectionRequest()
        injector.source = ReadOnlySelectionRequest(processID: 99)
        let context = await capture.capture(includeScreenshot: true, includeSelection: true, request: request)
        #expect(injector.requests.isEmpty)
        #expect(context.selectionStatus == "target-changed")
        #expect(context.selection == nil && context.screenshot == nil && context.source == nil)
    }

    @Test func sourceChangeDuringReadDiscardsContext() async {
        let injector = ContextTextInjector()
        var currentPID: pid_t = 42
        injector.onRead = { currentPID = 99 }
        let capture = AskContextCapture(injector: injector, permission: FakeScreenCapturePermission(granted: true), accessibilityTrusted: { true }, frontmostProcessID: { currentPID })
        let context = await capture.capture(includeScreenshot: false)
        #expect(injector.requests.first?.processID == 42)
        #expect(context.selectionStatus == "target-changed")
        #expect(context.selection == nil && context.sourceBundleID == nil)
    }

    @Test func sourceChangeDuringScreenshotDiscardsSelectionAndScreenshot() async {
        let injector = ContextTextInjector()
        var currentPID: pid_t = 42
        let capture = AskContextCapture(injector: injector, permission: FakeScreenCapturePermission(granted: true), accessibilityTrusted: { true }, frontmostProcessID: { currentPID },
                                       captureScreenshot: { _ in currentPID = 99; return "wrong app image" })
        let context = await capture.capture(includeScreenshot: true)
        #expect(context.selectionStatus == "target-changed")
        #expect(context.selection == nil && context.screenshot == nil)
    }

    @Test func cancellationDuringReadDiscardsResult() async {
        let injector = ContextTextInjector()
        var pending: CheckedContinuation<Void, Never>?
        injector.onRead = { await withCheckedContinuation { pending = $0 } }
        let capture = AskContextCapture(injector: injector, permission: FakeScreenCapturePermission(granted: true), accessibilityTrusted: { true }, frontmostProcessID: { 42 })
        let task = Task { await capture.capture(includeScreenshot: false) }
        while pending == nil { await Task.yield() }
        task.cancel()
        pending?.resume()
        let context = await task.value
        #expect(context.selectionStatus == "capture-cancelled")
        #expect(context.selection == nil)
    }

    @Test func missingSourceAndPermissionHaveDifferentStatuses() async {
        let injector = ContextTextInjector()
        let capture = AskContextCapture(injector: injector, permission: FakeScreenCapturePermission(granted: true), accessibilityTrusted: { false }, frontmostProcessID: { 42 })
        let denied = await capture.capture(includeScreenshot: false)
        #expect(denied.selectionStatus == "permission-missing")
        #expect(denied.sourceBundleID == "test.source")
        injector.source = ReadOnlySelectionRequest()
        let absent = await capture.capture(includeScreenshot: false)
        #expect(absent.selectionStatus == "source-unavailable")
        #expect(injector.requests.isEmpty)
    }
}
