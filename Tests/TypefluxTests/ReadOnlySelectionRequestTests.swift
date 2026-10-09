import AppKit
import Testing
@testable import Typeflux

@Suite("Pinned read-only selection", .serialized, .exclusiveUIState)
@MainActor
struct ReadOnlySelectionRequestTests {
    @Test func requestDoesNotRetargetAfterWaitingForTextOperation() async throws {
        let injector = AXTextInjector()
        injector.deliveryInProgress = true
        // A pinned, absent process must never fall back to the live frontmost app.
        let request = ReadOnlySelectionRequest(processID: -1, processName: "Old app")
        let task = Task { await injector.readOnlySelectionSnapshot(for: request) }
        for _ in 0..<5 { await Task.yield() }
        injector.deliveryInProgress = false
        let snapshot = await task.value
        #expect(snapshot.source == "target-changed")
        #expect(snapshot.selectedText == nil)
        #expect(!injector.deliveryInProgress)
    }

    @Test func cancelledQueueWaitDoesNotReadOrUnlockAnotherOperation() async {
        let injector = AXTextInjector()
        injector.deliveryInProgress = true
        let task = Task { await injector.readOnlySelectionSnapshot(for: .init(processID: -1)) }
        for _ in 0..<5 { await Task.yield() }
        task.cancel()
        let snapshot = await task.value
        #expect(snapshot.source == "capture-cancelled")
        #expect(injector.deliveryInProgress)
        injector.deliveryInProgress = false
    }

    @Test func capturedNativeSelectionSurvivesLaterFocusAndCannotAuthorizeReplacement() async throws {
        let injector = AXTextInjector()
        let pid = try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        let request = ReadOnlySelectionRequest(processID: pid, nativeSnapshot: TextSelectionSnapshot(
            selectedText: "Original selection", source: "typeflux-native", isEditable: true,
            isFocusedTarget: true, replacementContextID: UUID(), replacementSafety: .directAccessibility
        ))
        let result = await injector.readOnlySelectionSnapshot(for: request)
        #expect(result.selectedText == "Original selection")
        #expect(result.replacementContextID == nil)
        #expect(!result.canReplaceSelection)
        #expect(!injector.deliveryInProgress)
    }
}
