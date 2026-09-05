import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import Typeflux

@Suite("Delivery platform boundaries")
@MainActor
struct TextDeliveryPlatformTests {
    @Test(arguments: Array(AXTextInjector.opaqueContainerRoles).sorted(), [true, false])
    func authorizedOpaqueSelectionSurvivesWriteBackValidation(role: String, elementMatches: Bool) {
        let capability = AXTextInjector.targetCapability(
            role: role, hasSelectedRange: false, hasSettableTextAttributes: false
        )
        let safety = AXTextInjector.replacementSafety(
            source: "clipboard-copy", selectedRange: nil, isEditable: false, isFocusedTarget: true,
            selectedText: "selected text", intent: .explicitSelectionAction, capability: capability
        )
        #expect(safety == .verifiedPaste)
        #expect(AXTextInjector.capturedSelectionStillMatches(
            source: "clipboard-copy", elementMatches: elementMatches,
            capturedRange: nil, currentRange: nil,
            capturedText: "selected text", currentText: "selected text",
            capturedRole: role, currentRole: role,
            capturedPosition: CGPoint(x: 10, y: 10), currentPosition: CGPoint(x: 10, y: 10),
            capturedSize: CGSize(width: 400, height: 300), currentSize: CGSize(width: 400, height: 300),
            windowElementMatches: true, capturedWindowTitle: "Draft", currentWindowTitle: "Draft"
        ))
    }

    @Test(arguments: Array(AXTextInjector.nonEditableFalsePositiveRoles.subtracting(AXTextInjector.opaqueContainerRoles)).sorted())
    func knownNonEditableRolesRemainRejectedAtWriteBack(role: String) {
        #expect(!AXTextInjector.capturedSelectionStillMatches(
            source: "clipboard-copy", elementMatches: true,
            capturedRange: nil, currentRange: nil,
            capturedText: "selected text", currentText: "selected text",
            capturedRole: role, currentRole: role,
            windowElementMatches: true, capturedWindowTitle: "Draft", currentWindowTitle: "Draft"
        ))
    }

    @Test func opaqueSelectionStillRejectsChangedTextOrLostTarget() {
        #expect(!AXTextInjector.capturedSelectionStillMatches(
            source: "clipboard-copy", elementMatches: true,
            capturedRange: nil, currentRange: nil,
            capturedText: "original", currentText: "different",
            capturedRole: "AXWindow", currentRole: "AXWindow",
            windowElementMatches: true, capturedWindowTitle: "Draft", currentWindowTitle: "Draft"
        ))
        #expect(!AXTextInjector.capturedSelectionStillMatches(
            source: "clipboard-copy", elementMatches: false,
            capturedRange: nil, currentRange: nil,
            capturedText: "original", currentText: "original",
            capturedRole: "AXWindow", currentRole: "AXWindow",
            windowElementMatches: false, capturedWindowTitle: "Draft", currentWindowTitle: "Other"
        ))
    }

    @Test(arguments: [TextTargetCapability.opaque, .writable], ["clipboard-copy", "accessibility"])
    func explicitSelectionCanReplaceWithoutAXRange(capability: TextTargetCapability, source: String) {
        let safety = AXTextInjector.replacementSafety(
            source: source, selectedRange: nil, isEditable: false, isFocusedTarget: true,
            selectedText: " selected text ", intent: .explicitSelectionAction, capability: capability
        )
        #expect(safety == .verifiedPaste)
        let snapshot = TextSelectionSnapshot(
            selectedText: " selected text ", source: source, isEditable: false,
            isFocusedTarget: true, replacementSafety: safety
        )
        #expect(snapshot.canReplaceSelection)
        #expect(!WorkflowOverlayPresentationPolicy.shouldPresentResultDialog(for: snapshot))
    }

    @Test func explicitCopyDoesNotAuthorizeKnownReadOnlyOrMissingContext() {
        for capability: TextTargetCapability? in [.notWritable, nil] {
            #expect(AXTextInjector.replacementSafety(
                source: "clipboard-copy", selectedRange: nil, isEditable: false, isFocusedTarget: true,
                selectedText: "selected", intent: .explicitSelectionAction, capability: capability
            ) == .resultOnly)
        }
        #expect(AXTextInjector.replacementSafety(
            source: "clipboard-copy", selectedRange: nil, isEditable: false, isFocusedTarget: false,
            selectedText: "selected", intent: .explicitSelectionAction, capability: .opaque
        ) == .resultOnly)
        #expect(AXTextInjector.replacementSafety(
            source: "clipboard-copy", selectedRange: nil, isEditable: false, isFocusedTarget: true,
            selectedText: "", intent: .explicitSelectionAction, capability: .opaque
        ) == .resultOnly)
        #expect(AXTextInjector.replacementSafety(
            source: "clipboard-copy", selectedRange: nil, isEditable: false, isFocusedTarget: true,
            selectedText: "selected", intent: .automaticInsertion, capability: .opaque
        ) == .resultOnly)
    }

    @Test(arguments: ["generated", "\n\nWork with ChatGPT", "different", ""])
    func incompatibleOrStaleExternalEvidenceIsNotFailure(after: String) async {
        let observation = await TextDeliveryObserver.observe(
            text: "generated", before: "\n\nWork with ChatGPT",
            range: CFRange(location: 0, length: 0), read: { after }, pause: {}
        )
        #expect(observation == .unavailable)
        #expect(observation.result(method: .paste) == .unconfirmed(.paste))
    }

    @Test(arguments: [false, true])
    func externalEditorNeverUsesUnverifiedAXWrite(hasRange: Bool) async throws {
        let backend = AXTextDeliveryBackend(injector: AXTextInjector(), selection: nil)
        let target = AXTextDeliveryBackend.Target.external(.init(
            element: AXUIElementCreateApplication(getpid()), processID: getpid(),
            range: hasRange ? CFRange(location: 0, length: 0) : nil,
            before: "Work with ChatGPT"
        ))
        let result = try await backend.writeNative("generated", to: target)
        if case .unsupported = result {} else {
            Issue.record("External editors must use one verified paste, never an AX success acknowledgement")
        }
    }

    @Test(arguments: ["AXWindow", "AXWebArea", "AXScrollArea"])
    func focusSearchFindsActualFocusedDescendant(rootRole: String) {
        let result = FocusedTextTargetResolver.resolve(
            root: 0, role: { $0 == 0 ? rootRole : "AXTextArea" },
            nestedFocus: { _ in nil }, focused: { $0 == 2 },
            children: { $0 == 0 ? [1, 2] : [] }, matches: { (left: Int, right: Int) in left == right }
        )
        #expect(result == 2)
    }

    @Test func focusSearchDoesNotChooseAnUnfocusedEditableSibling() {
        let result = FocusedTextTargetResolver.resolve(
            root: 0, role: { $0 == 0 ? "AXWindow" : "AXTextArea" },
            nestedFocus: { _ in nil }, focused: { _ in false },
            children: { $0 == 0 ? [1] : [] }, matches: { (left: Int, right: Int) in left == right }
        )
        #expect(result == 0)
    }

    @Test func windowOnlyEditorRetainsOpaquePasteCapability() {
        let resolved = FocusedTextTargetResolver.resolve(
            root: 0, role: { _ in "AXWindow" }, nestedFocus: { _ in nil },
            focused: { _ in true }, children: { _ in [] },
            matches: { (left: Int, right: Int) in left == right }
        )
        #expect(resolved == 0)
        #expect(AXTextInjector.targetCapability(
            role: "AXWindow", hasSelectedRange: false, hasSettableTextAttributes: false
        ) == .opaque)
        #expect(AXTextInjector.targetCapability(
            role: "AXButton", hasSelectedRange: false, hasSettableTextAttributes: false
        ) == .notWritable)
    }

    @Test func focusSearchFollowsExplicitFocusChainAndRejectsCycles() {
        let roles = [0: "AXWindow", 1: "AXGroup", 2: "AXTextArea"]
        #expect(FocusedTextTargetResolver.resolve(
            root: 0, role: { roles[$0] }, nestedFocus: { $0 + 1 },
            focused: { _ in false }, children: { _ in [] }, matches: { (left: Int, right: Int) in left == right }
        ) == 2)
        #expect(FocusedTextTargetResolver.resolve(
            root: 0, role: { _ in "AXGroup" }, nestedFocus: { 1 - $0 },
            focused: { _ in false }, children: { _ in [] }, matches: { (left: Int, right: Int) in left == right }
        ) == nil)
    }

    @Test(arguments: ["AXButton", "AXWebArea"])
    func focusSearchKeepsDirectTargetForCapabilityClassification(role: String) {
        #expect(FocusedTextTargetResolver.resolve(
            root: 0, role: { _ in role }, nestedFocus: { _ in nil },
            focused: { _ in false }, children: { _ in [] }, matches: { (left: Int, right: Int) in left == right }
        ) == 0)
    }

    @Test func focusSearchBoundsMalformedChildrenAndExpiredBudget() {
        var calls = 0
        let result = FocusedTextTargetResolver.resolve(
            root: 0, role: { _ in "AXWindow" }, nestedFocus: { _ in nil },
            focused: { _ in false }, children: { _ in calls += 1; return [0, 1, 2, 3] }, matches: { (left: Int, right: Int) in left == right },
            budget: TextFocusSearchBudget(nodes: 8, seconds: 10)
        )
        #expect(result == 0)
        #expect(calls <= 4)
        #expect(FocusedTextTargetResolver.resolve(
            root: 0, role: { _ in "AXTextArea" }, nestedFocus: { _ in nil },
            focused: { _ in true }, children: { _ in [] }, matches: { (left: Int, right: Int) in left == right },
            budget: TextFocusSearchBudget(nodes: 0)
        ) == nil)
    }

    @Test(arguments: [false, true])
    func clipboardRestoresOnlyItsOwnPayload(userCopiedAgain: Bool) async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let injector = AXTextInjector()
        let backend = AXTextDeliveryBackend(injector: injector, selection: nil, pasteboard: board)
        let clipboard = try await backend.prepareClipboard()
        #expect(board.string(forType: .string) == "original")
        #expect(injector.writeTransientPasteboardString("generated", to: board))
        clipboard.changeCount = board.changeCount
        clipboard.dispatchedAt = ProcessInfo.processInfo.systemUptime - 2
        if userCopiedAgain {
            board.clearContents()
            board.setString("new user copy", forType: .string)
        }
        await backend.finishClipboard(clipboard, confirmed: false)
        #expect(board.string(forType: .string) == (userCopiedAgain ? "new user copy" : "original"))
    }

    @Test func unusedClipboardSnapshotDoesNotOverwriteNewCopy() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let backend = AXTextDeliveryBackend(injector: AXTextInjector(), selection: nil, pasteboard: board)
        let clipboard = try await backend.prepareClipboard()
        board.clearContents()
        board.setString("new copy", forType: .string)
        await backend.finishClipboard(clipboard, confirmed: true)
        #expect(board.string(forType: .string) == "new copy")
    }

    @Test func cancellationDoesNotSkipClipboardCleanup() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let injector = AXTextInjector()
        let backend = AXTextDeliveryBackend(injector: injector, selection: nil, pasteboard: board)
        let clipboard = try await backend.prepareClipboard()
        #expect(injector.writeTransientPasteboardString("result", to: board))
        clipboard.changeCount = board.changeCount
        clipboard.dispatchedAt = ProcessInfo.processInfo.systemUptime - 0.14
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await backend.finishClipboard(clipboard, confirmed: true)
        }
        await task.value
        #expect(board.string(forType: .string) == "original")
    }

    @Test func clipboardCaptureKeepsSelectionWhitespace() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let injector = AXTextInjector()
        let selected = injector.readSelectedTextViaCopy(milliseconds: 30, pasteboard: board) {
            board.clearContents()
            board.setString("  original\n", forType: .string)
        }
        #expect(selected == "  original\n")
    }

    @Test func focusSearchStopsAtBothLimits() {
        var clock: TimeInterval = 0
        var nodes = TextFocusSearchBudget(nodes: 2, seconds: 10, now: { clock })
        let taken1 = nodes.take()
        #expect(taken1)
        let taken2 = nodes.take()
        #expect(taken2)
        let taken3 = nodes.take()
        #expect(!taken3)
        var time = TextFocusSearchBudget(nodes: 100, seconds: 0.5, now: { clock })
        let taken4 = time.take()
        #expect(taken4)
        clock = 0.5
        let taken5 = time.take()
        #expect(!taken5)
        var zero = TextFocusSearchBudget(nodes: -1, seconds: 10)
        let taken6 = zero.take()
        #expect(!taken6)
    }

    @Test func textOperationLeasePreventsCopyDuringDeliveryAndSupportsCancellation() async throws {
        let injector = AXTextInjector()
        try await injector.acquireTextOperation()
        let waiting = Task { try await injector.acquireTextOperation() }
        waiting.cancel()
        do { try await waiting.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(injector.deliveryInProgress)
        injector.deliveryInProgress = false
        try await injector.acquireTextOperation()
        #expect(injector.deliveryInProgress)
        injector.deliveryInProgress = false
    }

    @Test func unknownPersonaContextCannotWrite() async {
        let injector = AXTextInjector()
        await #expect(throws: TextDeliveryError.selectionChanged) {
            try await injector.deliver(text: "new", to: .selection(TextSelectionSnapshot()))
        }
        #expect(!injector.deliveryInProgress)
    }

    @Test func axSelectionCanAuthorizePasteWithoutRangeButCopyCannot() {
        #expect(AXTextInjector.replacementSafety(
            source: "accessibility", selectedRange: nil, isEditable: true,
            isFocusedTarget: true, selectedText: "raw selection"
        ) == .verifiedPaste)
        #expect(AXTextInjector.replacementSafety(
            source: "clipboard-copy", selectedRange: nil, isEditable: true,
            isFocusedTarget: true, selectedText: "copied whole line"
        ) == .resultOnly)
        #expect(AXTextInjector.capturedSelectionStillMatches(
            source: "accessibility", elementMatches: true, capturedRange: nil, currentRange: nil,
            capturedText: "raw selection", currentText: "raw selection",
            capturedRole: "AXTextArea", currentRole: "AXTextArea", capturedWindowTitle: nil, currentWindowTitle: nil
        ))
    }

    @Test(arguments: [1, 3, 5])
    func observationIsBoundedAndAcceptsDelayedEdits(visibleAt: Int) async {
        var reads = 0
        let result = await TextDeliveryObserver.confirm(text: "new", before: "old", range: CFRange(location: 0, length: 3)) {
            reads += 1
            return reads >= visibleAt ? "new" : "old"
        } pause: {}
        #expect(result == (visibleAt <= 4))
        #expect(reads == min(visibleAt, 4))
    }

    @Test func missingBaselineAndReadErrorsNeverConfirm() async {
        var reads = 0
        #expect(await !TextDeliveryObserver.confirm(text: "new", before: nil, range: nil) {
            reads += 1
            return "new"
        } pause: {})
        #expect(reads == 0)
        #expect(await !TextDeliveryObserver.confirm(text: "new", before: "old", range: CFRange(location: 0, length: 3)) {
            throw TextDeliveryError.noInput
        } pause: {})
    }
}
