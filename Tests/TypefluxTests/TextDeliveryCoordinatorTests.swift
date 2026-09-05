import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite("Text delivery behavior")
@MainActor
struct TextDeliveryCoordinatorTests {
    @Test(arguments: [
        ("", 0, 0, "hello", "hello"),
        ("before after", 7, 0, "middle ", "before middle after"),
        ("before old after", 7, 3, "new", "before new after"),
        ("a😀b", 1, 2, "🌍", "a🌍b"),
        ("  line\nnext", 0, 7, "new\n", "new\nnext"),
        ("abc", 0, 3, " ", " "),
        ("abc", 3, 0, "\n", "abc\n")
    ])
    func editsActiveRange(example: (String, Int, Int, String, String)) async throws {
        let backend = FakeDeliveryBackend(text: example.0, range: CFRange(location: example.1, length: example.2))
        let result = try await TextDeliveryCoordinator(backend: backend).deliver(example.3, to: .currentInput)
        #expect(result == .delivered(.ax))
        #expect(backend.text == example.4)
        #expect(backend.events == ["resolve", "native"])
    }

    @Test func dictationFollowsNewInputAfterClipboardPreparation() async throws {
        let backend = FakeDeliveryBackend(text: "old", range: CFRange(location: 3, length: 0))
        backend.nativeResult = .unsupported
        backend.onPrepare = {
            backend.identity = 2
            backend.text = "new field"
            backend.range = CFRange(location: 4, length: 5)
        }
        let result = try await TextDeliveryCoordinator(backend: backend).deliver("destination", to: .currentInput)
        #expect(result == .delivered(.paste))
        #expect(backend.text == "new destination")
        #expect(backend.pasteIdentities == [2])
        #expect(backend.events == ["resolve", "native", "prepare", "resolve", "native", "paste", "observe", "cleanup"])
    }

    @Test func newNativeInputIsUsedAfterClipboardPreparation() async throws {
        let backend = FakeDeliveryBackend()
        backend.nativeResult = .unsupported
        backend.onPrepare = {
            backend.identity = 2
            backend.text = "new"
            backend.range = CFRange(location: 3, length: 0)
            backend.nativeResult = .acknowledged
        }
        let result = try await TextDeliveryCoordinator(backend: backend).deliver(" destination", to: .currentInput)
        #expect(result == .delivered(.ax))
        #expect(backend.text == "new destination")
        #expect(backend.pasteIdentities.isEmpty)
        #expect(backend.events.last == "cleanup")
    }

    @Test func switchingToNonInputShowsFailureWithoutWriting() async throws {
        let backend = FakeDeliveryBackend()
        backend.nativeResult = .unsupported
        backend.onPrepare = { backend.hasInput = false }
        await #expect(throws: TextDeliveryError.noInput) {
            try await TextDeliveryCoordinator(backend: backend).deliver("retained", to: .currentInput)
        }
        #expect(backend.pasteIdentities.isEmpty)
        #expect(backend.events.last == "cleanup")
    }

    @Test func personaNeverFollowsNewInput() async throws {
        let backend = FakeDeliveryBackend()
        backend.nativeResult = .unsupported
        backend.onPrepare = { backend.identity = 2 }
        await #expect(throws: TextDeliveryError.targetChanged) {
            try await TextDeliveryCoordinator(backend: backend).deliver(
                "rewritten", to: .selection(TextSelectionSnapshot(processID: 1))
            )
        }
        #expect(backend.pasteIdentities.isEmpty)
        #expect(backend.events.last == "cleanup")
    }

    @Test func personaCompletesCopyValidationBeforeClipboardLease() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("user clipboard", forType: .string)
        let backend = FakeDeliveryBackend(text: "selected", range: CFRange(location: 0, length: 8))
        backend.selectionProbeBoard = board
        backend.nativeResult = .unsupported
        let result = try await TextDeliveryCoordinator(backend: backend).deliver(
            "rewritten", to: .selection(TextSelectionSnapshot(processID: 1))
        )
        #expect(result == .delivered(.paste))
        #expect(backend.text == "rewritten")
        #expect(backend.pasteIdentities == [1])
        #expect(board.string(forType: .string) == "user clipboard")
        #expect(backend.events == ["resolve", "native", "resolve", "prepare", "native", "paste", "observe", "cleanup"])
    }

    @Test(arguments: [true, false])
    func ambiguousNativeWriteIsNeverPastedAgain(applied: Bool) async throws {
        let backend = FakeDeliveryBackend()
        backend.nativeResult = .unconfirmed
        backend.nativeApplied = applied
        let result = try await TextDeliveryCoordinator(backend: backend).deliver("new", to: .currentInput)
        #expect(result == (applied ? .delivered(.ax) : .notApplied(.ax)))
        #expect(backend.events == ["resolve", "native", "observe"])
    }

    @Test func ignoredPasteReturnsUnconfirmedAndCleansUp() async throws {
        let backend = FakeDeliveryBackend()
        backend.nativeResult = .unsupported
        backend.pasteApplied = false
        let result = try await TextDeliveryCoordinator(backend: backend).deliver("new", to: .currentInput)
        #expect(result == .unconfirmed(.paste))
        #expect(backend.pasteIdentities.count == 1)
        #expect(backend.cleanupConfirmed == false)
    }

    @Test(arguments: ["resolve", "native", "prepare", "paste"])
    func stageFailureDoesNotRetry(stage: String) async throws {
        let backend = FakeDeliveryBackend()
        backend.nativeResult = .unsupported
        backend.failureStage = stage
        await #expect(throws: TextDeliveryError.eventUnavailable) {
            try await TextDeliveryCoordinator(backend: backend).deliver("new", to: .currentInput)
        }
        #expect(backend.events.filter { $0 == stage }.count == 1)
        #expect(backend.events.contains("cleanup") == (stage == "paste"))
    }

    @Test func windowOnlyEditorAttemptsPasteWithoutInventingConfirmation() async throws {
        let resolved = FocusedTextTargetResolver.resolve(
            root: 0, role: { _ in "AXWindow" }, nestedFocus: { _ in nil },
            focused: { _ in true }, children: { _ in [] },
            matches: { (left: Int, right: Int) in left == right }
        )
        let backend = FakeDeliveryBackend()
        backend.hasInput = resolved != nil
        backend.nativeResult = .unsupported
        backend.canObserve = false
        let result = try await TextDeliveryCoordinator(backend: backend).deliver("new", to: .currentInput)
        #expect(backend.text == "new")
        #expect(backend.pasteIdentities == [1])
        #expect(result == .unconfirmed(.paste))
        #expect(backend.events.last == "cleanup")
    }

    @Test func emptyOutputNeverTouchesTarget() async {
        let backend = FakeDeliveryBackend()
        await #expect(throws: TextDeliveryError.emptyOutput) {
            try await TextDeliveryCoordinator(backend: backend).deliver("", to: .currentInput)
        }
        #expect(backend.events.isEmpty)
    }

    @Test func cancellationAfterPreparationCleansUpWithoutPaste() async {
        let backend = FakeDeliveryBackend()
        backend.nativeResult = .unsupported
        backend.onPrepare = { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task {
            try await TextDeliveryCoordinator(backend: backend).deliver("new", to: .currentInput)
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(backend.pasteIdentities.isEmpty)
        #expect(backend.events.last == "cleanup")
    }

    @Test func cancelledBeforeStartDoesNotResolve() async {
        let backend = FakeDeliveryBackend()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TextDeliveryCoordinator(backend: backend).deliver("new", to: .currentInput)
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(backend.events.isEmpty)
    }

    @Test func cancellationAfterDispatchStillCleansUpWithoutRetry() async throws {
        let backend = FakeDeliveryBackend()
        backend.nativeResult = .unsupported
        backend.onPaste = { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task {
            try await TextDeliveryCoordinator(backend: backend).deliver("new", to: .currentInput)
        }
        #expect(try await task.value == .delivered(.paste))
        #expect(backend.events.last == "cleanup")
        #expect(backend.pasteIdentities.count == 1)
    }

    @Test func overlapIsRejectedAndLeaseIsReleasedAfterFailure() async throws {
        let backend = FakeDeliveryBackend()
        let coordinator = TextDeliveryCoordinator(backend: backend)
        backend.onNative = {
            await #expect(throws: TextDeliveryError.busy) {
                try await coordinator.deliver("overlap", to: .currentInput)
            }
        }
        backend.failureStage = "native"
        await #expect(throws: TextDeliveryError.eventUnavailable) {
            try await coordinator.deliver("first", to: .currentInput)
        }
        backend.failureStage = nil
        backend.onNative = nil
        #expect(try await coordinator.deliver("second", to: .currentInput) == .delivered(.ax))
    }

    @Test func evidenceRejectsExistingSubstringAndInvalidRanges() {
        #expect(!TextDeliveryEvidence.confirms(text: "hello", before: nil, range: nil, after: "hello"))
        #expect(!TextDeliveryEvidence.confirms(text: "hello", before: "hello", range: CFRange(location: 0, length: 5), after: "hello"))
        for range in [CFRange(location: -1, length: 1), CFRange(location: 0, length: -1),
                      CFRange(location: Int.max, length: Int.max), CFRange(location: 1, length: Int.max)] {
            #expect(!TextDeliveryEvidence.confirms(text: "x", before: "a", range: range, after: "x"))
        }
    }

    @Test(arguments: ["hello\n", " hello ", "\tindented\n", "😀 text\n"])
    func capturedSelectionRetainsExactText(raw: String) {
        let range = CFRange(location: 0, length: raw.utf16.count)
        let captured = AXTextInjector.validSelectionText(
            selectedText: raw, selectedRange: range, value: raw, placeholder: nil, title: nil, role: "AXTextArea"
        )
        #expect(captured == raw)
        #expect(AXTextInjector.capturedSelectionStillMatches(
            source: "accessibility", elementMatches: true, capturedRange: range, currentRange: range,
            capturedText: captured, currentText: raw, capturedRole: "AXTextArea", currentRole: "AXTextArea",
            capturedWindowTitle: nil, currentWindowTitle: nil
        ))
    }
}

@MainActor
private final class FakeDeliveryBackend: TextDeliveryBackend {
    struct Target {
        let identity: Int
        let before: String
        let range: CFRange
    }
    typealias Clipboard = Int
    var text: String
    var range: CFRange
    var selectionProbeBoard: NSPasteboard?
    var identity = 1
    var hasInput = true
    var nativeResult: NativeTextWriteResult = .acknowledged
    var nativeApplied = true
    var pasteApplied = true
    var canObserve = true
    var failureStage: String?
    var onPrepare: (() -> Void)?
    var onPaste: (() -> Void)?
    var onNative: (() async -> Void)?
    var events: [String] = []
    var pasteIdentities: [Int] = []
    var cleanupConfirmed: Bool?

    init(text: String = "old", range: CFRange = CFRange(location: 0, length: 3)) {
        self.text = text
        self.range = range
    }

    func stage(_ name: String) throws {
        events.append(name)
        if failureStage == name { throw TextDeliveryError.eventUnavailable }
    }

    func resolve(_ destination: TextDeliveryDestination) async throws -> Target {
        try stage("resolve")
        guard hasInput else { throw TextDeliveryError.noInput }
        if case let .selection(snapshot) = destination, snapshot.processID != pid_t(identity) {
            throw TextDeliveryError.selectionChanged
        }
        if case .selection = destination, let board = selectionProbeBoard {
            _ = AXTextInjector().readSelectedTextViaCopy(milliseconds: 30, pasteboard: board) {
                board.clearContents()
                board.setString(self.text, forType: .string)
            }
        }
        return Target(identity: identity, before: text, range: range)
    }

    func writeNative(_ text: String, to target: Target) async throws -> NativeTextWriteResult {
        await onNative?()
        try stage("native")
        if nativeApplied, nativeResult != .unsupported { try apply(text, to: target) }
        return nativeResult
    }

    func prepareClipboard() async throws -> Int {
        try stage("prepare")
        onPrepare?()
        return selectionProbeBoard?.changeCount ?? 1
    }

    func paste(_ text: String, to target: Target, clipboard: Int) async throws {
        try stage("paste")
        guard identity == target.identity else { throw TextDeliveryError.targetChanged }
        if let board = selectionProbeBoard, board.changeCount != clipboard {
            throw TextDeliveryError.clipboardUnavailable
        }
        pasteIdentities.append(target.identity)
        if pasteApplied { try apply(text, to: target) }
        onPaste?()
    }

    func apply(_ result: String, to target: Target) throws {
        guard identity == target.identity,
              let updated = AXTextInjector.replacingUTF16Range(in: text, range: target.range, with: result)
        else { throw TextDeliveryError.targetChanged }
        text = updated
    }

    func observe(_ result: String, in target: Target) async -> TextDeliveryObservation {
        events.append("observe")
        guard canObserve else { return .unavailable }
        if TextDeliveryEvidence.confirms(text: result, before: target.before, range: target.range, after: text) {
            return .confirmed
        }
        return text == target.before && nativeResult != .unsupported ? .unchanged : .unavailable
    }

    func finishClipboard(_: Int, confirmed: Bool) async {
        events.append("cleanup")
        cleanupConfirmed = confirmed
    }
}
