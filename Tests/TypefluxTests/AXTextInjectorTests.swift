import ApplicationServices
@testable import Typeflux
import XCTest

private final class LockedTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func setTrue() {
        lock.lock()
        storedValue = true
        lock.unlock()
    }
}

final class AXTextInjectorTests: XCTestCase {
    func testSelectionReplacementWorkRunsOffMainThread() async throws {
        let injector = AXTextInjector()

        let ranOnMainThread = try await injector.performSelectionReplacementWork {
            Thread.isMainThread
        }

        XCTAssertFalse(ranOnMainThread)
    }

    func testCancelledQueuedSelectionReplacementWorkDoesNotRun() async throws {
        let injector = AXTextInjector()
        let queueBlocked = DispatchSemaphore(value: 0)
        let releaseQueue = DispatchSemaphore(value: 0)
        injector.selectionReplacementQueue.async {
            queueBlocked.signal()
            releaseQueue.wait()
        }
        XCTAssertEqual(queueBlocked.wait(timeout: .now() + 1), .success)

        let workRan = LockedTestFlag()
        let task = Task {
            try await injector.performSelectionReplacementWork {
                workRan.setTrue()
            }
        }
        task.cancel()
        releaseQueue.signal()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(workRan.value)
    }

    func testSelectionReplacementContextCanOnlyBeConsumedOnce() {
        let injector = AXTextInjector()
        let context = AXTextInjector.SelectionContext(
            element: AXUIElementCreateSystemWide(),
            range: CFRange(location: 0, length: 5),
            processID: 42,
            processName: "Notes",
            selectedText: "hello",
            role: "AXTextArea",
            windowTitle: "Draft",
            isFocusedTarget: true,
            source: "accessibility",
            capturedAt: Date()
        )
        let contextID = injector.registerSelectionContext(context)

        XCTAssertNotNil(injector.consumeSelectionContext(id: contextID))
        XCTAssertNil(injector.consumeSelectionContext(id: contextID))
    }

    func testSelectionReplacementContextRegistryIsBounded() {
        let injector = AXTextInjector()

        for offset in 0 ... AXTextInjector.maximumSelectionContextCount {
            _ = injector.registerSelectionContext(AXTextInjector.SelectionContext(
                element: AXUIElementCreateSystemWide(),
                range: CFRange(location: offset, length: 1),
                processID: 42,
                processName: "Notes",
                selectedText: "x",
                role: "AXTextArea",
                windowTitle: "Draft",
                isFocusedTarget: true,
                source: "accessibility",
                capturedAt: Date().addingTimeInterval(Double(offset))
            ))
        }

        XCTAssertEqual(injector.selectionContexts.count, AXTextInjector.maximumSelectionContextCount)
    }

    func testCapturedSelectionAcceptsRebuiltElementOnlyWithMatchingSemanticIdentity() {
        let range = CFRange(location: 4, length: 7)

        XCTAssertTrue(AXTextInjector.capturedSelectionStillMatches(
            source: "accessibility",
            elementMatches: false,
            capturedRange: range,
            currentRange: range,
            capturedText: "meeting",
            currentText: "meeting",
            capturedRole: "AXTextArea",
            currentRole: "AXTextArea",
            capturedPosition: CGPoint(x: 10, y: 20),
            currentPosition: CGPoint(x: 10, y: 20),
            capturedSize: CGSize(width: 300, height: 120),
            currentSize: CGSize(width: 300, height: 120),
            capturedWindowTitle: "Draft",
            currentWindowTitle: "Draft"
        ))
    }

    func testCapturedSelectionRejectsChangedTextOrRange() {
        let range = CFRange(location: 4, length: 7)

        XCTAssertFalse(AXTextInjector.capturedSelectionStillMatches(
            source: "accessibility",
            elementMatches: true,
            capturedRange: range,
            currentRange: CFRange(location: 5, length: 7),
            capturedText: "meeting",
            currentText: "meeting",
            capturedRole: "AXTextArea",
            currentRole: "AXTextArea",
            capturedWindowTitle: "Draft",
            currentWindowTitle: "Draft"
        ))
        XCTAssertFalse(AXTextInjector.capturedSelectionStillMatches(
            source: "accessibility",
            elementMatches: true,
            capturedRange: range,
            currentRange: range,
            capturedText: "meeting",
            currentText: "changed",
            capturedRole: "AXTextArea",
            currentRole: "AXTextArea",
            capturedWindowTitle: "Draft",
            currentWindowTitle: "Draft"
        ))
    }

    func testAccessibilitySelectionUsesElementIdentityWhenWindowTitleChanges() {
        let range = CFRange(location: 4, length: 7)

        XCTAssertTrue(AXTextInjector.capturedSelectionStillMatches(
            source: "accessibility",
            elementMatches: false,
            capturedRange: range,
            currentRange: range,
            capturedText: "meeting",
            currentText: "meeting",
            capturedRole: "AXTextArea",
            currentRole: "AXTextArea",
            capturedIdentifier: "editor",
            currentIdentifier: "editor",
            capturedWindowTitle: "Draft",
            currentWindowTitle: "Draft — Edited"
        ))
    }

    func testClipboardCapturedSelectionAcceptsExactOrSemanticElementIdentity() {
        XCTAssertTrue(AXTextInjector.capturedSelectionStillMatches(
            source: "clipboard-copy",
            elementMatches: true,
            capturedRange: nil,
            currentRange: nil,
            capturedText: "meeting",
            currentText: "meeting",
            capturedRole: nil,
            currentRole: nil,
            capturedWindowTitle: "Draft",
            currentWindowTitle: "Draft"
        ))
        XCTAssertTrue(AXTextInjector.capturedSelectionStillMatches(
            source: "clipboard-copy",
            elementMatches: false,
            capturedRange: nil,
            currentRange: nil,
            capturedText: "meeting",
            currentText: "meeting",
            capturedRole: "AXTextArea",
            currentRole: "AXTextArea",
            capturedPosition: CGPoint(x: 10, y: 20),
            currentPosition: CGPoint(x: 10, y: 20),
            capturedSize: CGSize(width: 300, height: 120),
            currentSize: CGSize(width: 300, height: 120),
            capturedWindowTitle: "Draft",
            currentWindowTitle: "Draft"
        ))
        XCTAssertTrue(AXTextInjector.capturedSelectionStillMatches(
            source: "clipboard-copy",
            elementMatches: false,
            capturedRange: nil,
            currentRange: nil,
            capturedText: "meeting",
            currentText: "meeting",
            capturedRole: "AXTextArea",
            currentRole: "AXTextArea",
            capturedPosition: CGPoint(x: 10, y: 20),
            currentPosition: CGPoint(x: 10, y: 20),
            capturedSize: CGSize(width: 300, height: 120),
            currentSize: CGSize(width: 300, height: 120),
            capturedWindowTitle: nil,
            currentWindowTitle: nil
        ))
        XCTAssertFalse(AXTextInjector.capturedSelectionStillMatches(
            source: "clipboard-copy",
            elementMatches: false,
            capturedRange: nil,
            currentRange: nil,
            capturedText: "meeting",
            currentText: "meeting",
            capturedRole: "AXTextArea",
            currentRole: "AXTextArea",
            capturedWindowTitle: "Draft",
            currentWindowTitle: "Draft"
        ))
        XCTAssertFalse(AXTextInjector.capturedSelectionStillMatches(
            source: "clipboard-copy",
            elementMatches: false,
            capturedRange: nil,
            currentRange: nil,
            capturedText: "meeting",
            currentText: "changed",
            capturedRole: "AXTextArea",
            currentRole: "AXTextArea",
            capturedWindowTitle: "Draft",
            currentWindowTitle: "Draft"
        ))
        XCTAssertFalse(AXTextInjector.capturedSelectionStillMatches(
            source: "clipboard-copy",
            elementMatches: false,
            capturedRange: nil,
            currentRange: nil,
            capturedText: "meeting",
            currentText: "meeting",
            capturedRole: "AXTextArea",
            currentRole: "AXTextArea",
            capturedWindowTitle: "Draft",
            currentWindowTitle: "Other Draft"
        ))
        XCTAssertFalse(AXTextInjector.capturedSelectionStillMatches(
            source: "clipboard-copy",
            elementMatches: false,
            capturedRange: nil,
            currentRange: nil,
            capturedText: "meeting",
            currentText: "meeting",
            capturedRole: "AXTextArea",
            currentRole: "AXTextArea",
            capturedIdentifier: "composer-a",
            currentIdentifier: "composer-b",
            capturedPosition: CGPoint(x: 10, y: 20),
            currentPosition: CGPoint(x: 10, y: 20),
            capturedSize: CGSize(width: 300, height: 120),
            currentSize: CGSize(width: 300, height: 120),
            capturedWindowTitle: "Draft",
            currentWindowTitle: "Draft"
        ))
        XCTAssertFalse(AXTextInjector.capturedSelectionStillMatches(
            source: "clipboard-copy",
            elementMatches: false,
            capturedRange: nil,
            currentRange: nil,
            capturedText: "meeting",
            currentText: "meeting",
            capturedRole: "AXTextArea",
            currentRole: "AXTextArea",
            capturedPosition: CGPoint(x: 10, y: 20),
            currentPosition: CGPoint(x: 40, y: 20),
            capturedSize: CGSize(width: 300, height: 120),
            currentSize: CGSize(width: 300, height: 120),
            capturedWindowTitle: "Draft",
            currentWindowTitle: "Draft"
        ))
    }

    func testClipboardFingerprintAcceptsMissingRoleBecomingEditableContainerInSameWindow() {
        let assessment = AXTextInjector.selectionFingerprintAssessment(
            source: "clipboard-copy",
            elementMatches: false,
            capturedRange: nil,
            currentRange: CFRange(location: 0, length: 0),
            capturedText: "meeting",
            currentText: "meeting",
            capturedRole: nil,
            currentRole: "AXGroup",
            capturedSubrole: nil,
            currentSubrole: nil,
            capturedIdentifier: nil,
            currentIdentifier: nil,
            capturedPosition: nil,
            currentPosition: nil,
            capturedSize: nil,
            currentSize: nil,
            windowElementMatches: true,
            capturedWindowPosition: nil,
            currentWindowPosition: nil,
            capturedWindowSize: nil,
            currentWindowSize: nil,
            capturedWindowTitle: "ChatGPT",
            currentWindowTitle: "ChatGPT"
        )

        XCTAssertTrue(assessment.accepted)
        XCTAssertEqual(assessment.role, .unavailable)
        XCTAssertEqual(assessment.window, .match)
    }

    func testClipboardFingerprintAcceptsCompatibleEditableRoleDrift() {
        XCTAssertTrue(AXTextInjector.capturedSelectionStillMatches(
            source: "clipboard-copy",
            elementMatches: false,
            capturedRange: nil,
            currentRange: nil,
            capturedText: "meeting",
            currentText: "meeting",
            capturedRole: "AXWebArea",
            currentRole: "AXTextArea",
            capturedIdentifier: "composer",
            currentIdentifier: "composer",
            capturedWindowTitle: "Draft",
            currentWindowTitle: "Draft"
        ))
    }

    func testClipboardFingerprintRejectsNonEditableRoleEvenWhenWindowMatches() {
        let assessment = AXTextInjector.selectionFingerprintAssessment(
            source: "clipboard-copy",
            elementMatches: false,
            capturedRange: nil,
            currentRange: nil,
            capturedText: "meeting",
            currentText: "meeting",
            capturedRole: nil,
            currentRole: "AXButton",
            capturedSubrole: nil,
            currentSubrole: nil,
            capturedIdentifier: nil,
            currentIdentifier: nil,
            capturedPosition: nil,
            currentPosition: nil,
            capturedSize: nil,
            currentSize: nil,
            windowElementMatches: true,
            capturedWindowPosition: nil,
            currentWindowPosition: nil,
            capturedWindowSize: nil,
            currentWindowSize: nil,
            capturedWindowTitle: "Draft",
            currentWindowTitle: "Draft"
        )

        XCTAssertFalse(assessment.accepted)
        XCTAssertEqual(assessment.role, .conflict)
    }

    func testClipboardFingerprintRejectsSameTitleForDifferentWindow() {
        let assessment = AXTextInjector.selectionFingerprintAssessment(
            source: "clipboard-copy",
            elementMatches: false,
            capturedRange: nil,
            currentRange: nil,
            capturedText: "meeting",
            currentText: "meeting",
            capturedRole: "AXGroup",
            currentRole: "AXGroup",
            capturedSubrole: nil,
            currentSubrole: nil,
            capturedIdentifier: nil,
            currentIdentifier: nil,
            capturedPosition: nil,
            currentPosition: nil,
            capturedSize: nil,
            currentSize: nil,
            windowElementMatches: false,
            capturedWindowPosition: nil,
            currentWindowPosition: nil,
            capturedWindowSize: nil,
            currentWindowSize: nil,
            capturedWindowTitle: "Draft",
            currentWindowTitle: "Draft"
        )

        XCTAssertFalse(assessment.accepted)
        XCTAssertEqual(assessment.window, .conflict)
    }

    func testClipboardFingerprintUsesAvailableStrongEvidenceWhenIdentifierDisappears() {
        let assessment = AXTextInjector.selectionFingerprintAssessment(
            source: "clipboard-copy",
            elementMatches: false,
            capturedRange: nil,
            currentRange: nil,
            capturedText: "meeting",
            currentText: "meeting",
            capturedRole: "AXGroup",
            currentRole: "AXGroup",
            capturedSubrole: nil,
            currentSubrole: nil,
            capturedIdentifier: "composer",
            currentIdentifier: nil,
            capturedPosition: nil,
            currentPosition: nil,
            capturedSize: nil,
            currentSize: nil,
            windowElementMatches: true,
            capturedWindowPosition: nil,
            currentWindowPosition: nil,
            capturedWindowSize: nil,
            currentWindowSize: nil,
            capturedWindowTitle: "Draft",
            currentWindowTitle: "Draft"
        )

        XCTAssertTrue(assessment.accepted)
        XCTAssertEqual(assessment.identifier, .unavailable)
    }

    func testClipboardFingerprintAcceptsRebuiltWindowWithMatchingFrame() {
        XCTAssertTrue(AXTextInjector.capturedSelectionStillMatches(
            source: "clipboard-copy",
            elementMatches: false,
            capturedRange: nil,
            currentRange: nil,
            capturedText: "meeting",
            currentText: "meeting",
            capturedRole: "AXGroup",
            currentRole: "AXGroup",
            windowElementMatches: false,
            capturedWindowPosition: CGPoint(x: 100, y: 80),
            currentWindowPosition: CGPoint(x: 100, y: 80),
            capturedWindowSize: CGSize(width: 900, height: 700),
            currentWindowSize: CGSize(width: 900, height: 700),
            capturedWindowTitle: "Draft",
            currentWindowTitle: "Draft"
        ))
    }

    func testClipboardFingerprintRejectsExplicitSubroleConflict() {
        let assessment = AXTextInjector.selectionFingerprintAssessment(
            source: "clipboard-copy",
            elementMatches: false,
            capturedRange: nil,
            currentRange: nil,
            capturedText: "meeting",
            currentText: "meeting",
            capturedRole: "AXGroup",
            currentRole: "AXGroup",
            capturedSubrole: "AXDocument",
            currentSubrole: "AXDialog",
            capturedIdentifier: nil,
            currentIdentifier: nil,
            capturedPosition: nil,
            currentPosition: nil,
            capturedSize: nil,
            currentSize: nil,
            windowElementMatches: true,
            capturedWindowPosition: nil,
            currentWindowPosition: nil,
            capturedWindowSize: nil,
            currentWindowSize: nil,
            capturedWindowTitle: "Draft",
            currentWindowTitle: "Draft"
        )

        XCTAssertFalse(assessment.accepted)
        XCTAssertEqual(assessment.subrole, .conflict)
        XCTAssertFalse(assessment.diagnosticSummary.contains("meeting"))
    }

    func testTargetCapabilityDistinguishesWritableNonWritableAndOpaqueTargets() {
        XCTAssertEqual(
            AXTextInjector.targetCapability(
                role: "AXTextArea",
                hasSelectedRange: false,
                hasSettableTextAttributes: false
            ),
            .writable
        )
        XCTAssertEqual(
            AXTextInjector.targetCapability(
                role: "AXButton",
                hasSelectedRange: true,
                hasSettableTextAttributes: true
            ),
            .notWritable
        )
        XCTAssertEqual(
            AXTextInjector.targetCapability(
                role: "AXGroup",
                hasSelectedRange: false,
                hasSettableTextAttributes: false
            ),
            .opaque
        )
        XCTAssertEqual(
            AXTextInjector.targetCapability(
                role: "AXGroup",
                hasSelectedRange: true,
                hasSettableTextAttributes: false
            ),
            .writable
        )
        XCTAssertEqual(
            AXTextInjector.targetCapability(
                role: "AXWindow",
                hasSelectedRange: false,
                hasSettableTextAttributes: false
            ),
            .opaque
        )
    }

    func testReplacingUTF16RangeHandlesEmojiAndRejectsInvalidRanges() {
        XCTAssertEqual(
            AXTextInjector.replacingUTF16Range(
                in: "A😀B",
                range: CFRange(location: 1, length: 2),
                with: "hello"
            ),
            "AhelloB"
        )
        XCTAssertNil(
            AXTextInjector.replacingUTF16Range(
                in: "short",
                range: CFRange(location: 4, length: 2),
                with: "x"
            )
        )
    }

    func testPasteboardDeliveryProbeSeparatesRequestsBeforeAndAfterDispatch() {
        let clock = TestMonotonicClock(now: 1)
        let contaminatedProbe = PasteboardDeliveryProbe(text: "hello", now: { clock.read() })
        contaminatedProbe.pasteboard(
            nil,
            item: NSPasteboardItem(),
            provideDataForType: .string
        )
        clock.set(2)
        contaminatedProbe.markDispatched()

        XCTAssertTrue(contaminatedProbe.wasRequestedBeforeDispatch)
        XCTAssertFalse(contaminatedProbe.wasRequestedAfterDispatch)

        let deliveredProbe = PasteboardDeliveryProbe(text: "hello", now: { clock.read() })
        deliveredProbe.markDispatched()
        clock.set(3)
        deliveredProbe.pasteboard(
            nil,
            item: NSPasteboardItem(),
            provideDataForType: .string
        )

        XCTAssertFalse(deliveredProbe.wasRequestedBeforeDispatch)
        XCTAssertTrue(deliveredProbe.wasRequestedAfterDispatch)
    }

    func testFinalPasteVerificationUsesLatestReadbackAndDeliveryEvidence() {
        XCTAssertEqual(
            AXTextInjector.finalPasteVerification(
                lastReadback: .indeterminate,
                payloadRequestedAfterDispatch: true,
                payloadRequestedBeforeDispatch: false,
                targetStableThroughout: true
            ),
            .success
        )
        XCTAssertEqual(
            AXTextInjector.finalPasteVerification(
                lastReadback: .failure("input-text-unchanged"),
                payloadRequestedAfterDispatch: true,
                payloadRequestedBeforeDispatch: false,
                targetStableThroughout: true
            ),
            .failure("input-text-unchanged")
        )
        XCTAssertEqual(
            AXTextInjector.finalPasteVerification(
                lastReadback: .indeterminate,
                payloadRequestedAfterDispatch: true,
                payloadRequestedBeforeDispatch: false,
                targetStableThroughout: false
            ),
            .failure("focused-target-changed")
        )
        XCTAssertEqual(
            AXTextInjector.finalPasteVerification(
                lastReadback: .indeterminate,
                payloadRequestedAfterDispatch: false,
                payloadRequestedBeforeDispatch: true,
                targetStableThroughout: true
            ),
            .failure("pasteboard-request-contaminated-before-dispatch")
        )
        XCTAssertEqual(
            AXTextInjector.finalPasteVerification(
                lastReadback: .indeterminate,
                payloadRequestedAfterDispatch: false,
                payloadRequestedBeforeDispatch: false,
                targetStableThroughout: true
            ),
            .failure("pasteboard-payload-not-requested")
        )
    }

    func testSuccessfulAXWriteOnlyFallsBackForStableUnchangedInput() {
        XCTAssertTrue(
            AXTextInjector.successfulAXWriteIsCommitted(verification: .success)
        )
        XCTAssertTrue(
            AXTextInjector.successfulAXWriteIsCommitted(verification: .indeterminate)
        )
        XCTAssertTrue(
            AXTextInjector.successfulAXWriteIsCommitted(
                verification: .failure("focused-process-changed")
            )
        )
        XCTAssertFalse(
            AXTextInjector.successfulAXWriteIsCommitted(
                verification: .failure("input-text-unchanged")
            )
        )
    }

    private final class InjectorBox: @unchecked Sendable {
        let value = AXTextInjector()
    }

    func testPerformAXReadOnMainActorRunsClosureOnMainThread() async {
        let injector = AXTextInjector()

        let isMainThread = await injector.performAXReadOnMainActor {
            Thread.isMainThread
        }

        XCTAssertTrue(isMainThread)
    }

    func testPerformAXOperationOnMainThreadRunsClosureOnMainThreadFromBackgroundQueue() async {
        let injector = InjectorBox()

        let isMainThread = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let value = injector.value.performAXOperationOnMainThread {
                    Thread.isMainThread
                }
                continuation.resume(returning: value)
            }
        }

        XCTAssertTrue(isMainThread)
    }

    func testShouldPreferEditableDescendantForWindowWhenCaretRangeExists() {
        let candidate = AXTextInjector.FocusResolutionCandidate(
            role: "AXGroup",
            isEditable: true,
            isFocused: false,
            selectedRange: CFRange(location: 0, length: 0)
        )

        let result = AXTextInjector.shouldPreferEditableDescendant(
            overWindowRole: "AXWindow",
            candidate: candidate
        )

        XCTAssertTrue(result)
    }

    func testShouldNotPreferEditableDescendantWhenWindowRoleDoesNotMatch() {
        let candidate = AXTextInjector.FocusResolutionCandidate(
            role: "AXGroup",
            isEditable: true,
            isFocused: false,
            selectedRange: CFRange(location: 0, length: 0)
        )

        let result = AXTextInjector.shouldPreferEditableDescendant(
            overWindowRole: "AXGroup",
            candidate: candidate
        )

        XCTAssertFalse(result)
    }

    func testShouldNotPreferEditableDescendantWhenCandidateIsAlreadyFocused() {
        let candidate = AXTextInjector.FocusResolutionCandidate(
            role: "AXGroup",
            isEditable: true,
            isFocused: true,
            selectedRange: CFRange(location: 0, length: 0)
        )

        let result = AXTextInjector.shouldPreferEditableDescendant(
            overWindowRole: "AXWindow",
            candidate: candidate
        )

        XCTAssertFalse(result)
    }

    func testShouldNotPreferEditableDescendantWhenCandidateIsNotEditable() {
        let candidate = AXTextInjector.FocusResolutionCandidate(
            role: "AXGroup",
            isEditable: false,
            isFocused: false,
            selectedRange: CFRange(location: 0, length: 0)
        )

        let result = AXTextInjector.shouldPreferEditableDescendant(
            overWindowRole: "AXWindow",
            candidate: candidate
        )

        XCTAssertFalse(result)
    }

    func testShouldNotPreferEditableDescendantForScrollbarFalsePositive() {
        let candidate = AXTextInjector.FocusResolutionCandidate(
            role: "AXScrollBar",
            isEditable: true,
            isFocused: false,
            selectedRange: nil
        )

        let result = AXTextInjector.shouldPreferEditableDescendant(
            overWindowRole: "AXWindow",
            candidate: candidate
        )

        XCTAssertFalse(result)
    }

    func testShouldTreatEmptyValueOnGenericEditableRoleAsUnreadable() {
        let result = AXTextInjector.shouldTreatAXValueAsUnreadable(
            role: "AXGroup",
            value: "",
            selectedRange: CFRange(location: 0, length: 0)
        )

        XCTAssertTrue(result)
    }

    func testShouldNotTreatEmptyValueOnNativeTextFieldAsUnreadable() {
        let result = AXTextInjector.shouldTreatAXValueAsUnreadable(
            role: "AXTextField",
            value: "",
            selectedRange: CFRange(location: 0, length: 0)
        )

        XCTAssertFalse(result)
    }

    func testDocumentURLParsesFileURLAttribute() {
        let url = AXTextInjector.documentURL(fromAXAttributeValue: "file:///Users/example/doc.md")

        XCTAssertEqual(url?.path, "/Users/example/doc.md")
    }

    func testDocumentURLParsesAbsolutePathAttribute() {
        let url = AXTextInjector.documentURL(fromAXAttributeValue: "/Users/example/doc.md")

        XCTAssertEqual(url?.path, "/Users/example/doc.md")
    }

    func testVisibleTextCandidateAttributesIncludeStaticTextValues() {
        XCTAssertEqual(
            AXTextInjector.visibleTextCandidateAttributes(for: "AXStaticText"),
            [kAXValueAttribute as String, kAXDescriptionAttribute as String, kAXTitleAttribute as String]
        )
    }

    func testVisibleTextCandidateAttributesIgnoreWindowTitles() {
        XCTAssertTrue(AXTextInjector.visibleTextCandidateAttributes(for: "AXWindow").isEmpty)
    }

    func testJoinedVisibleTextCandidatesDeduplicatesAdjacentLines() {
        let text = AXTextInjector.joinedVisibleTextCandidates([
            " first line ",
            "first line",
            "second line",
            ""
        ])

        XCTAssertEqual(text, "first line\nsecond line")
    }

    func testJoinedVisibleTextCandidatesAppliesCharacterLimit() {
        let longLine = String(repeating: "a", count: AXTextInjector.visibleTextContextMaxCharacters + 1)

        let text = AXTextInjector.joinedVisibleTextCandidates([
            "first line",
            longLine,
            "third line"
        ])

        XCTAssertEqual(text, "first line")
    }

    func testFirstSessionContentsFindsNestedSublimeBufferContainingSelection() {
        let object: [String: Any] = [
            "windows": [
                [
                    "buffers": [
                        [
                            "contents": "before\nselected paragraph\nafter"
                        ]
                    ]
                ]
            ]
        ]

        let text = AXTextInjector.firstSessionContents(containing: "selected paragraph", in: object)

        XCTAssertEqual(text, "before\nselected paragraph\nafter")
    }

    func testFirstSessionContentsMatchesNormalizedSelection() {
        let object: [String: Any] = [
            "buffers": [
                [
                    "contents": "before\n做一个“能用的原型”和做一个“可以给别人用的产品”之间\nafter"
                ]
            ]
        ]

        let text = AXTextInjector.firstSessionContents(
            containing: "做一个\"能用的原型\" 和做一个\"可以给别人用的产品\"之间",
            in: object
        )

        XCTAssertEqual(text, "before\n做一个“能用的原型”和做一个“可以给别人用的产品”之间\nafter")
    }

    func testFirstSessionContentsMatchesSelectionFragmentWhenBufferChanged() {
        let object: [String: Any] = [
            "buffers": [
                [
                    "contents": "最初我以为花一两天就能跑通。结果发现，做一个\"能用的原型\"和做一个\"可以给别人用的产品\"之间，差的是一个月的废寝忘食寝食难安。"
                ]
            ]
        ]

        let text = AXTextInjector.firstSessionContents(
            containing: "最初我以为花一两天就能跑通。结果发现，做一个\"能用的原型\"和做一个\"可以给别人用的产品\"之间，差的是一个月的废寝忘食。",
            in: object
        )

        XCTAssertNotNil(text)
    }

    func testFirstSublimeSessionContextReadsSelectedSheetCursorRange() {
        let object: [String: Any] = [
            "windows": [
                [
                    "buffers": [
                        [
                            "contents": "before cursor.after cursor"
                        ]
                    ],
                    "groups": [
                        [
                            "sheets": [
                                [
                                    "buffer": 0,
                                    "selected": true,
                                    "settings": [
                                        "selection": [
                                            [13, 13]
                                        ],
                                        "settings": [
                                            "auto_name": "draft"
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let context = AXTextInjector.firstSublimeSessionContext(
            selectedText: "before cursor",
            windowTitle: "draft",
            in: object
        )

        XCTAssertEqual(context?.text, "before cursor.after cursor")
        XCTAssertEqual(context?.selectedRange?.location, 13)
        XCTAssertEqual(context?.selectedRange?.length, 0)
    }

    func testZedEditorContextUsesContentsContainingSelection() {
        let injector = AXTextInjector(settingsStore: nil)

        let context = injector.zedEditorContext(
            contents: "before\nselected paragraph\nafter",
            bufferPath: "/tmp/example.md",
            selectedRange: nil,
            selectedText: "selected paragraph",
            windowTitle: "project - example.md"
        )

        XCTAssertEqual(context?.text, "before\nselected paragraph\nafter")
    }

    func testZedEditorContextReadsBufferPathWhenContentsMissing() throws {
        let injector = AXTextInjector(settingsStore: nil)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypefluxZedContext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("draft.md")
        try "before\nselected paragraph\nafter".write(to: fileURL, atomically: true, encoding: .utf8)

        let context = injector.zedEditorContext(
            contents: nil,
            bufferPath: fileURL.path,
            selectedRange: CFRange(location: 7, length: 18),
            selectedText: "selected paragraph",
            windowTitle: "project - draft.md"
        )

        XCTAssertEqual(context?.text, "before\nselected paragraph\nafter")
        XCTAssertEqual(context?.selectedRange?.location, 7)
        XCTAssertEqual(context?.selectedRange?.length, 18)
    }

    func testBrowserAutomationKindDetectsCommonBrowsers() {
        XCTAssertEqual(
            AXTextInjector.browserAutomationKind(for: "com.google.Chrome"),
            AXTextInjector.BrowserAutomationKind(bundleIdentifier: "com.google.Chrome", command: .chromium)
        )
        XCTAssertEqual(
            AXTextInjector.browserAutomationKind(for: "com.microsoft.edgemac"),
            AXTextInjector.BrowserAutomationKind(bundleIdentifier: "com.microsoft.edgemac", command: .chromium)
        )
        XCTAssertEqual(
            AXTextInjector.browserAutomationKind(for: "com.apple.Safari"),
            AXTextInjector.BrowserAutomationKind(bundleIdentifier: "com.apple.Safari", command: .safari)
        )
        XCTAssertNil(AXTextInjector.browserAutomationKind(for: "com.openai.atlas"))
    }

    func testBrowserDOMContextAppleScriptUsesBrowserBundleIdentifier() {
        let script = AXTextInjector.browserDOMContextAppleScript(
            bundleIdentifier: "com.google.Chrome",
            javascript: "return \"hello\";",
            command: .chromium
        )

        XCTAssertTrue(script.contains("tell application id \"com.google.Chrome\""))
        XCTAssertTrue(script.contains("execute active tab of front window javascript"))
        XCTAssertTrue(script.contains("return \\\"hello\\\";"))
    }

    func testBrowserDOMContextParsesUTF16SelectionRange() {
        let json = """
        {"ok":true,"text":"hi 😄 there","selectionStart":6,"selectionEnd":11}
        """

        let context = AXTextInjector.browserDOMContext(fromJSON: json)

        XCTAssertEqual(context?.text, "hi 😄 there")
        XCTAssertEqual(context?.selectedRange?.location, 6)
        XCTAssertEqual(context?.selectedRange?.length, 5)
    }

    func testBrowserDOMContextRejectsEmptyPayload() {
        let json = """
        {"ok":false,"text":"","selectionStart":0,"selectionEnd":0}
        """

        XCTAssertNil(AXTextInjector.browserDOMContext(fromJSON: json))
    }

    func testBrowserDOMContextPayloadPreservesFailureReason() {
        let json = """
        {"ok":false,"reason":"no-editable-root","text":"","selectionStart":0,"selectionEnd":0}
        """

        let payload = AXTextInjector.browserDOMContextPayload(fromJSON: json)

        XCTAssertEqual(payload?.reason, "no-editable-root")
        XCTAssertNil(payload.flatMap(AXTextInjector.browserDOMContext(from:)))
    }

    func testBrowserAXValuePolicyPrefersDOMBeforeChromeAddressField() {
        XCTAssertTrue(AXTextInjector.shouldPreferApplicationStateContextBeforeAXValue(
            bundleIdentifier: "com.google.Chrome",
            role: "AXTextField",
            isFocusedTarget: false
        ))
        XCTAssertTrue(AXTextInjector.shouldSuppressAXValueContext(
            bundleIdentifier: "com.google.Chrome",
            role: "AXTextField",
            isFocusedTarget: false
        ))
    }

    func testBrowserAXValuePolicyKeepsFocusedWebTextAreaFallback() {
        XCTAssertFalse(AXTextInjector.shouldSuppressAXValueContext(
            bundleIdentifier: "com.google.Chrome",
            role: "AXTextArea",
            isFocusedTarget: true
        ))
    }

    func testAppleScriptFailureReasonDetectsChromeJavaScriptDisabled() {
        let reason = AXTextInjector.appleScriptFailureReason(from: [
            NSAppleScript.errorNumber: NSNumber(value: 12),
            NSAppleScript.errorMessage: "Executing JavaScript through AppleScript is turned off."
        ])

        XCTAssertEqual(reason, "browser-dom-javascript-from-apple-events-disabled")
    }

    func testInputContextFailureReasonIncludesApplicationStateFailure() {
        let injector = AXTextInjector(settingsStore: nil)
        injector.lastApplicationStateFailureReason = "browser-dom-javascript-from-apple-events-disabled"

        let reason = injector.inputContextFailureReason(
            defaultReason: "focused-element-not-editable",
            contextReason: "focused-element-not-editable-context",
            contextText: nil
        )

        XCTAssertEqual(reason, "focused-element-not-editable-browser-dom-javascript-from-apple-events-disabled")
    }

    func testContextTextSourcePrefersDocumentOverApplicationState() {
        XCTAssertEqual(
            AXTextInjector.contextTextSource(
                documentText: "document",
                applicationStateText: "state",
                visibleText: "visible"
            ),
            "document"
        )
        XCTAssertEqual(
            AXTextInjector.contextTextSource(
                documentText: nil,
                applicationStateText: "state",
                visibleText: "visible"
            ),
            "application-state"
        )
    }

    func testEditableCandidateScoreRejectsScrollbarFalsePositive() {
        let candidate = AXTextInjector.FocusResolutionCandidate(
            role: "AXScrollBar",
            isEditable: true,
            isFocused: false,
            selectedRange: nil
        )

        XCTAssertEqual(AXTextInjector.editableCandidateScore(for: candidate), 0)
    }

    func testEditableCandidateScorePrefersGenericEditorWithCaret() {
        let candidate = AXTextInjector.FocusResolutionCandidate(
            role: "AXGroup",
            isEditable: true,
            isFocused: false,
            selectedRange: CFRange(location: 0, length: 0)
        )

        XCTAssertGreaterThan(AXTextInjector.editableCandidateScore(for: candidate), 0)
    }

    func testShouldAllowClipboardSelectionReplacementWithoutAXBaseline() {
        let result = AXTextInjector.shouldAllowClipboardSelectionReplacementWithoutAXBaseline(
            replaceSelection: true,
            selectionSource: "clipboard-copy",
            focusMatched: true,
            baselineAvailable: false
        )

        XCTAssertTrue(result)
    }

    func testShouldNotAllowClipboardSelectionReplacementWithoutFocusMatch() {
        let result = AXTextInjector.shouldAllowClipboardSelectionReplacementWithoutAXBaseline(
            replaceSelection: true,
            selectionSource: "clipboard-copy",
            focusMatched: false,
            baselineAvailable: false
        )

        XCTAssertFalse(result)
    }

    func testShouldNotTreatNonEmptyValueAsUnreadable() {
        let result = AXTextInjector.shouldTreatAXValueAsUnreadable(
            role: "AXGroup",
            value: "hello",
            selectedRange: CFRange(location: 0, length: 0)
        )

        XCTAssertFalse(result)
    }

    func testEvaluatePasteVerificationReturnsSuccessWhenInsertedTextAppears() {
        let before = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXTextArea",
            text: "Hello",
            selectedRange: CFRange(location: 5, length: 0),
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil
        )
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXTextArea",
            text: "Hello world",
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: " world",
            replaceSelection: false,
            targetProcessID: 42,
            before: before,
            after: after
        )

        XCTAssertEqual(result, .success)
    }

    func testEvaluatePasteVerificationRequiresExactCaretTransition() {
        let before = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXTextArea",
            text: "world Hello",
            selectedRange: CFRange(location: 11, length: 0),
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil
        )
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXTextArea",
            text: "world Hello",
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "world",
            replaceSelection: false,
            targetProcessID: 42,
            before: before,
            after: after
        )

        XCTAssertEqual(result, .failure("input-text-unchanged"))
    }

    func testEvaluatePasteVerificationDoesNotTreatWhitespaceChangeAsUnchanged() {
        let before = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXTextArea",
            text: "Hello",
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil
        )
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXTextArea",
            text: "Hello\n",
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "\n",
            replaceSelection: false,
            targetProcessID: 42,
            before: before,
            after: after
        )

        XCTAssertEqual(result, .indeterminate)
    }

    func testEvaluatePasteVerificationFailsWhenFocusedProcessChanges() {
        let before = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXTextArea",
            text: "Hello",
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil
        )
        let after = CurrentInputTextSnapshot(
            processID: 99,
            processName: "Safari",
            role: "AXTextField",
            text: "Hello",
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "world",
            replaceSelection: false,
            targetProcessID: 42,
            before: before,
            after: after
        )

        XCTAssertEqual(result, .failure("focused-process-changed"))
    }

    func testEvaluatePasteVerificationFailsWhenReadableInputTextDoesNotChangeForInsert() {
        let before = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            role: "AXTextArea",
            text: "Hello",
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil,
            textSource: "ax-value"
        )
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            role: "AXTextArea",
            text: "Hello",
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil,
            textSource: "ax-value"
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "world",
            replaceSelection: false,
            targetProcessID: 42,
            before: before,
            after: after
        )

        XCTAssertEqual(result, .failure("input-text-unchanged"))
    }

    func testEvaluatePasteVerificationFailsWhenReadableInputTextDoesNotChangeForReplace() {
        let before = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            role: "AXTextArea",
            text: "Hello",
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil,
            textSource: "ax-value"
        )
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            role: "AXTextArea",
            text: "Hello",
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil,
            textSource: "ax-value"
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "world",
            replaceSelection: true,
            targetProcessID: 42,
            before: before,
            after: after
        )

        XCTAssertEqual(result, .failure("input-text-unchanged"))
    }

    func testEvaluatePasteVerificationIsIndeterminateWhenBrowserAXValueIsUnchangedForInsert() {
        let before = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Arc",
            bundleIdentifier: "company.thebrowser.Browser",
            role: "AXTextArea",
            text: "\n",
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil,
            textSource: "ax-value"
        )
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Arc",
            bundleIdentifier: "company.thebrowser.Browser",
            role: "AXTextArea",
            text: "\n",
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil,
            textSource: "ax-value"
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "这是语音输入",
            replaceSelection: false,
            targetProcessID: 42,
            before: before,
            after: after
        )

        XCTAssertEqual(result, .indeterminate)
    }

    func testEvaluatePasteVerificationIsIndeterminateWhenKnownBrowserAXValueIsStale() {
        let before = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Arc",
            bundleIdentifier: "company.thebrowser.Browser",
            role: "AXTextArea",
            text: "Stale editor value",
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil,
            textSource: "ax-value"
        )
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Arc",
            bundleIdentifier: "company.thebrowser.Browser",
            role: "AXTextArea",
            text: "Stale editor value",
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil,
            textSource: "ax-value"
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "new text",
            replaceSelection: false,
            targetProcessID: 42,
            before: before,
            after: after
        )

        XCTAssertEqual(result, .indeterminate)
    }

    func testEvaluatePasteVerificationIsIndeterminateWhenUnknownBrowserLikeAXValueIsEmptyForInsert() {
        let before = CurrentInputTextSnapshot(
            processID: 42,
            processName: "New Browser",
            bundleIdentifier: "com.example.NewBrowser",
            role: "AXTextArea",
            text: "\n",
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil,
            textSource: "ax-value"
        )
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "New Browser",
            bundleIdentifier: "com.example.NewBrowser",
            role: "AXTextArea",
            text: "\n",
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil,
            textSource: "ax-value"
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "这是语音输入",
            replaceSelection: false,
            targetProcessID: 42,
            before: before,
            after: after
        )

        XCTAssertEqual(result, .indeterminate)
    }

    func testEvaluatePasteVerificationIsIndeterminateWhenTextCannotBeReadBack() {
        let before = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXTextArea",
            text: "Hello",
            isEditable: true,
            isFocusedTarget: true,
            failureReason: nil
        )
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXUnknown",
            text: nil,
            isEditable: true,
            isFocusedTarget: true,
            failureReason: "missing-ax-value"
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "world",
            replaceSelection: false,
            targetProcessID: 42,
            before: before,
            after: after
        )

        XCTAssertEqual(result, .indeterminate)
    }

    func testEvaluatePasteVerificationIsIndeterminateForInsertWhenFocusedElementIsNotReadable() {
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Codex",
            role: "AXWindow",
            text: nil,
            isEditable: false,
            isFocusedTarget: false,
            failureReason: "focused-element-not-editable"
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "hello",
            replaceSelection: false,
            targetProcessID: 42,
            before: nil,
            after: after
        )

        XCTAssertEqual(result, .indeterminate)
    }

    func testEvaluatePasteVerificationStillFailsForReplaceWhenFocusedElementIsNotEditable() {
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Codex",
            role: "AXWindow",
            text: nil,
            isEditable: false,
            isFocusedTarget: false,
            failureReason: "focused-element-not-editable"
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "hello",
            replaceSelection: true,
            targetProcessID: 42,
            before: nil,
            after: after
        )

        XCTAssertEqual(result, .failure("focused-element-not-editable"))
    }

    func testEvaluatePasteVerificationFailsForInsertWhenAccessibilityIsNotTrusted() {
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Notes",
            role: "AXTextArea",
            text: nil,
            isEditable: false,
            isFocusedTarget: false,
            failureReason: "accessibility-not-trusted"
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "hello",
            replaceSelection: false,
            targetProcessID: 42,
            before: nil,
            after: after
        )

        XCTAssertEqual(result, .failure("accessibility-not-trusted"))
    }

    func testShouldActivateTargetBeforePasteReturnsFalseWhenFlagDisabled() {
        let result = AXTextInjector.shouldActivateTargetBeforePaste(
            flagEnabled: false,
            targetProcessID: 42,
            frontmostProcessID: 99
        )

        XCTAssertFalse(result)
    }

    func testShouldActivateTargetBeforePasteReturnsFalseWhenTargetMatchesFrontmost() {
        let result = AXTextInjector.shouldActivateTargetBeforePaste(
            flagEnabled: true,
            targetProcessID: 42,
            frontmostProcessID: 42
        )

        XCTAssertFalse(result)
    }

    func testShouldActivateTargetBeforePasteReturnsFalseWhenTargetProcessIDMissing() {
        let result = AXTextInjector.shouldActivateTargetBeforePaste(
            flagEnabled: true,
            targetProcessID: nil,
            frontmostProcessID: 42
        )

        XCTAssertFalse(result)
    }

    func testShouldActivateTargetBeforePasteReturnsTrueWhenTargetDiffersFromFrontmost() {
        let result = AXTextInjector.shouldActivateTargetBeforePaste(
            flagEnabled: true,
            targetProcessID: 42,
            frontmostProcessID: 99
        )

        XCTAssertTrue(result)
    }

    func testShouldActivateTargetBeforePasteReturnsTrueWhenFrontmostIsNil() {
        let result = AXTextInjector.shouldActivateTargetBeforePaste(
            flagEnabled: true,
            targetProcessID: 42,
            frontmostProcessID: nil
        )

        XCTAssertTrue(result)
    }

    func testShouldReactivateProcessForSelectionRestoreSkipsWhenAlreadyFrontmost() {
        // Chromium-based apps reset focus to the URL bar when activated while
        // already frontmost; the caller must not issue a redundant activate().
        let result = AXTextInjector.shouldReactivateProcessForSelectionRestore(
            targetProcessID: 42,
            frontmostProcessID: 42
        )

        XCTAssertFalse(result)
    }

    func testShouldReactivateProcessForSelectionRestoreActivatesWhenTargetDiffers() {
        let result = AXTextInjector.shouldReactivateProcessForSelectionRestore(
            targetProcessID: 42,
            frontmostProcessID: 99
        )

        XCTAssertTrue(result)
    }

    func testShouldReactivateProcessForSelectionRestoreActivatesWhenFrontmostUnknown() {
        let result = AXTextInjector.shouldReactivateProcessForSelectionRestore(
            targetProcessID: 42,
            frontmostProcessID: nil
        )

        XCTAssertTrue(result)
    }

    func testShouldReactivateProcessForSelectionRestoreSkipsWhenTargetUnknown() {
        let result = AXTextInjector.shouldReactivateProcessForSelectionRestore(
            targetProcessID: nil,
            frontmostProcessID: 42
        )

        XCTAssertFalse(result)
    }

    func testPasteEventDispatchMethodUsesHIDTapWhenFlagEnabled() {
        let result = AXTextInjector.pasteEventDispatchMethod(
            flagEnabled: true,
            targetProcessID: 42
        )

        XCTAssertEqual(result, .hidTap)
    }

    func testPasteEventDispatchMethodUsesHIDTapWhenFlagEnabledAndTargetMissing() {
        let result = AXTextInjector.pasteEventDispatchMethod(
            flagEnabled: true,
            targetProcessID: nil
        )

        XCTAssertEqual(result, .hidTap)
    }

    func testPasteEventDispatchMethodUsesPostToPidWhenFlagDisabledAndTargetAvailable() {
        let result = AXTextInjector.pasteEventDispatchMethod(
            flagEnabled: false,
            targetProcessID: 42
        )

        XCTAssertEqual(result, .postToPid)
    }

    func testPasteEventDispatchMethodFallsBackToHIDTapWhenFlagDisabledAndTargetMissing() {
        let result = AXTextInjector.pasteEventDispatchMethod(
            flagEnabled: false,
            targetProcessID: nil
        )

        XCTAssertEqual(result, .hidTap)
    }

    func testShouldPerformStrictPasteVerificationReturnsFalseForInsertEvenWhenFlagEnabled() {
        let result = AXTextInjector.shouldPerformStrictPasteVerification(
            replaceSelection: false,
            strictFallbackEnabled: true
        )

        XCTAssertFalse(result)
    }

    func testShouldPerformStrictPasteVerificationReturnsFalseForReplaceWhenFlagDisabled() {
        let result = AXTextInjector.shouldPerformStrictPasteVerification(
            replaceSelection: true,
            strictFallbackEnabled: false
        )

        XCTAssertFalse(result)
    }

    func testShouldPerformStrictPasteVerificationReturnsTrueForReplaceWhenFlagEnabled() {
        let result = AXTextInjector.shouldPerformStrictPasteVerification(
            replaceSelection: true,
            strictFallbackEnabled: true
        )

        XCTAssertTrue(result)
    }

    func testShouldPerformStrictPasteVerificationReturnsFalseForInsertWhenFlagDisabled() {
        let result = AXTextInjector.shouldPerformStrictPasteVerification(
            replaceSelection: false,
            strictFallbackEnabled: false
        )

        XCTAssertFalse(result)
    }

    func testShouldAttemptPasteVerificationReturnsFalseForInsertWhenFlagDisabled() {
        let result = AXTextInjector.shouldAttemptPasteVerification(
            replaceSelection: false,
            strictFallbackEnabled: false
        )

        XCTAssertFalse(result)
    }

    func testShouldAttemptPasteVerificationReturnsFalseForInsertWhenFlagEnabled() {
        let result = AXTextInjector.shouldAttemptPasteVerification(
            replaceSelection: false,
            strictFallbackEnabled: true
        )

        XCTAssertFalse(result)
    }

    func testShouldAttemptPasteVerificationReturnsFalseForReplaceWhenFlagDisabled() {
        let result = AXTextInjector.shouldAttemptPasteVerification(
            replaceSelection: true,
            strictFallbackEnabled: false
        )

        XCTAssertFalse(result)
    }

    func testShouldAttemptPasteVerificationReturnsTrueForReplaceWhenFlagEnabled() {
        let result = AXTextInjector.shouldAttemptPasteVerification(
            replaceSelection: true,
            strictFallbackEnabled: true
        )

        XCTAssertTrue(result)
    }

    func testShouldRestoreCapturedPasteboardReturnsTrueWhenChangeCountMatches() {
        let result = AXTextInjector.shouldRestoreCapturedPasteboard(
            capturedChangeCount: 42,
            currentChangeCount: 42
        )

        XCTAssertTrue(result)
    }

    func testShouldRestoreCapturedPasteboardReturnsFalseWhenChangeCountAdvanced() {
        // Another writer (user copy, clipboard manager, etc.) updated the
        // pasteboard after our transcription write. Restoring would clobber
        // their fresh content, so we must skip.
        let result = AXTextInjector.shouldRestoreCapturedPasteboard(
            capturedChangeCount: 42,
            currentChangeCount: 43
        )

        XCTAssertFalse(result)
    }

    func testClipboardSelectionProbeSkipsCollapsedSelection() {
        XCTAssertTrue(AXTextInjector.shouldSkipClipboardSelectionProbe(
            selectedRange: CFRange(location: 12, length: 0)
        ))
    }

    func testClipboardSelectionProbeAllowsUnknownOrNonEmptySelection() {
        XCTAssertFalse(AXTextInjector.shouldSkipClipboardSelectionProbe(selectedRange: nil))
        XCTAssertFalse(AXTextInjector.shouldSkipClipboardSelectionProbe(
            selectedRange: CFRange(location: 4, length: 8)
        ))
    }

    func testClipboardCopyProbeRejectsStaleTextWhenCopyDoesNothing() {
        let injector = AXTextInjector()
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("previous transcription", forType: .string)

        let selectedText = injector.readSelectedTextViaCopy(
            milliseconds: 1,
            pasteboard: pasteboard,
            sendCopy: {}
        )

        XCTAssertNil(selectedText)
        XCTAssertEqual(pasteboard.string(forType: .string), "previous transcription")
    }

    func testClipboardCopyProbeRejectsChangeWithoutCopiedText() {
        let injector = AXTextInjector()
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("previous transcription", forType: .string)

        let selectedText = injector.readSelectedTextViaCopy(
            milliseconds: 25,
            pasteboard: pasteboard,
            sendCopy: {
                pasteboard.clearContents()
            }
        )

        XCTAssertNil(selectedText)
        XCTAssertEqual(pasteboard.string(forType: .string), "previous transcription")
    }

    func testClipboardCopyProbeReturnsNewSelectionAndRestoresClipboard() {
        let injector = AXTextInjector()
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("original clipboard", forType: .string)

        let selectedText = injector.readSelectedTextViaCopy(
            milliseconds: 25,
            pasteboard: pasteboard,
            sendCopy: {
                pasteboard.clearContents()
                pasteboard.setString("selected text", forType: .string)
            }
        )

        XCTAssertEqual(selectedText, "selected text")
        XCTAssertEqual(pasteboard.string(forType: .string), "original clipboard")
    }

    func testClipboardProbeDoesNotOverwriteLaterClipboardChange() throws {
        let injector = AXTextInjector()
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("original clipboard", forType: .string)
        let snapshot = try XCTUnwrap(AXTextInjector.capturePasteboardSnapshot(
            from: pasteboard,
            maximumBytes: 1024
        ))

        pasteboard.clearContents()
        pasteboard.setString("new clipboard", forType: .string)
        injector.restorePasteboardIfUnchanged(
            snapshot,
            to: pasteboard,
            expectedChangeCount: snapshot.changeCount
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "new clipboard")
    }

    func testCapturePasteboardSnapshotPreservesAllRepresentations() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let item = NSPasteboardItem()
        item.setString("original", forType: .string)
        item.setData(Data([0x01, 0x02, 0x03]), forType: .init("dev.typeflux.test-data"))
        pasteboard.writeObjects([item])

        let snapshot = try XCTUnwrap(AXTextInjector.capturePasteboardSnapshot(
            from: pasteboard,
            maximumBytes: 1_024
        ))

        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.changeCount, pasteboard.changeCount)
        XCTAssertEqual(snapshot.items[0].representations.count, 2)
        XCTAssertEqual(
            snapshot.items[0].representations.first { $0.type == .string }?.data,
            "original".data(using: .utf8)
        )
        XCTAssertEqual(
            snapshot.items[0].representations.first {
                $0.type == .init("dev.typeflux.test-data")
            }?.data,
            Data([0x01, 0x02, 0x03])
        )
    }

    func testWriteTransientPasteboardStringMarksPayloadForClipboardHistoryExclusion() {
        let injector = AXTextInjector()
        let pasteboard = NSPasteboard.withUniqueName()

        XCTAssertTrue(injector.writeTransientPasteboardString("dictation", to: pasteboard))

        XCTAssertEqual(pasteboard.string(forType: .string), "dictation")
        XCTAssertNotNil(pasteboard.data(forType: AXTextInjector.transientPasteboardType))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    }

    func testTransientPasteboardPayloadCanBeCapturedAndRestored() throws {
        let injector = AXTextInjector()
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("original", forType: .string)
        let snapshot = try XCTUnwrap(AXTextInjector.capturePasteboardSnapshot(
            from: pasteboard,
            maximumBytes: 1_024
        ))

        XCTAssertTrue(injector.writeTransientPasteboardString("dictation", to: pasteboard))
        injector.restorePasteboard(snapshot, to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertNil(pasteboard.data(forType: AXTextInjector.transientPasteboardType))
    }

    func testCapturePasteboardSnapshotPreservesEmptyClipboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()

        let snapshot = try XCTUnwrap(AXTextInjector.capturePasteboardSnapshot(
            from: pasteboard,
            maximumBytes: 1_024
        ))

        XCTAssertTrue(snapshot.items.isEmpty)
    }

    func testCapturePasteboardSnapshotRejectsOversizedClipboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setData(
            Data(repeating: 0x01, count: 5),
            forType: .init("dev.typeflux.oversized-test-data")
        )

        XCTAssertNil(AXTextInjector.capturePasteboardSnapshot(
            from: pasteboard,
            maximumBytes: 4
        ))
    }

    func testCapturePasteboardSnapshotRejectsNegativeSizeLimit() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("original", forType: .string)

        XCTAssertNil(AXTextInjector.capturePasteboardSnapshot(
            from: pasteboard,
            maximumBytes: -1
        ))
    }

    func testCapturePasteboardSnapshotWithTimeoutReturnsAvailableSnapshot() throws {
        let injector = AXTextInjector()
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("original", forType: .string)

        let snapshot = try XCTUnwrap(injector.capturePasteboardSnapshotWithTimeout(
            from: pasteboard
        ))

        XCTAssertEqual(snapshot.changeCount, pasteboard.changeCount)
        XCTAssertEqual(snapshot.items.count, 1)
    }

    func testCapturePasteboardSnapshotWithTimeoutRejectsBlockingProvider() {
        let injector = AXTextInjector()
        let pasteboard = NSPasteboard.withUniqueName()
        let provider = SlowPasteboardDataProvider(delay: 0.75, text: "original")
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        pasteboard.writeObjects([item])

        let startedAt = Date()
        let snapshot = injector.capturePasteboardSnapshotWithTimeout(from: pasteboard)

        XCTAssertNil(snapshot)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.6)
    }

    func testRestorePasteboardRestoresSnapshotAndClearsTemporaryText() throws {
        let injector = AXTextInjector()
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("original", forType: .string)
        let snapshot = try XCTUnwrap(AXTextInjector.capturePasteboardSnapshot(
            from: pasteboard,
            maximumBytes: 1_024
        ))
        pasteboard.clearContents()
        pasteboard.setString("transcription", forType: .string)

        injector.restorePasteboard(snapshot, to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testRestorePasteboardRestoresEmptySnapshot() throws {
        let injector = AXTextInjector()
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        let snapshot = try XCTUnwrap(AXTextInjector.capturePasteboardSnapshot(
            from: pasteboard,
            maximumBytes: 1_024
        ))
        pasteboard.setString("transcription", forType: .string)

        injector.restorePasteboard(snapshot, to: pasteboard)

        XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)
    }

    func testRestorePasteboardAfterPasteRestoresWhenClipboardIsUnchanged() async throws {
        let injector = AXTextInjector()
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("original", forType: .string)
        let snapshot = try XCTUnwrap(AXTextInjector.capturePasteboardSnapshot(
            from: pasteboard,
            maximumBytes: 1_024
        ))
        pasteboard.clearContents()
        pasteboard.setString("transcription", forType: .string)
        let injectionChangeCount = pasteboard.changeCount

        injector.restorePasteboardAfterPaste(
            snapshot,
            to: pasteboard,
            capturedChangeCount: injectionChangeCount,
            delayNanoseconds: 1_000_000
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testRestorePasteboardAfterPasteKeepsNewUserClipboard() async throws {
        let injector = AXTextInjector()
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("original", forType: .string)
        let snapshot = try XCTUnwrap(AXTextInjector.capturePasteboardSnapshot(
            from: pasteboard,
            maximumBytes: 1_024
        ))
        pasteboard.clearContents()
        pasteboard.setString("transcription", forType: .string)
        let injectionChangeCount = pasteboard.changeCount

        injector.restorePasteboardAfterPaste(
            snapshot,
            to: pasteboard,
            capturedChangeCount: injectionChangeCount,
            delayNanoseconds: 25_000_000
        )
        pasteboard.clearContents()
        pasteboard.setString("new user copy", forType: .string)
        try await Task.sleep(nanoseconds: 75_000_000)

        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }

    func testUnverifiedPasteRestoreDelayIsLongerThanVerifiedDelay() {
        // Slow clipboard consumers (iTerm2, Terminal, Warp) may not read the
        // pasteboard until well after Cmd+V is dispatched. When we cannot
        // verify the paste landed, the restore delay must be long enough to
        // avoid racing the consumer's read.
        XCTAssertGreaterThan(
            AXTextInjector.unverifiedPasteRestoreDelayNanoseconds,
            AXTextInjector.verifiedPasteRestoreDelayNanoseconds
        )
        XCTAssertGreaterThan(
            AXTextInjector.unverifiedPasteRestoreDelayNanoseconds,
            AXTextInjector.legacyPasteRestoreDelayNanoseconds
        )
    }

    func testEvaluatePasteVerificationIsIndeterminateWhenReadableTextIsUnchangedOnHeuristicTarget() {
        let before = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Google Chrome",
            role: "AXTextField",
            text: "x.com/home",
            isEditable: true,
            isFocusedTarget: false,
            failureReason: nil
        )
        let after = CurrentInputTextSnapshot(
            processID: 42,
            processName: "Google Chrome",
            role: "AXTextField",
            text: "x.com/home",
            isEditable: true,
            isFocusedTarget: false,
            failureReason: nil
        )

        let result = AXTextInjector.evaluatePasteVerification(
            insertedText: "The input method is not feasible in this scenario.",
            replaceSelection: false,
            targetProcessID: 42,
            before: before,
            after: after
        )

        XCTAssertEqual(result, .indeterminate)
    }
}

private final class TestMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: TimeInterval

    init(now: TimeInterval) {
        self.now = now
    }

    func read() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    func set(_ value: TimeInterval) {
        lock.lock()
        now = value
        lock.unlock()
    }
}

private final class SlowPasteboardDataProvider: NSObject, NSPasteboardItemDataProvider {
    private let delay: TimeInterval
    private let text: String

    init(delay: TimeInterval, text: String) {
        self.delay = delay
        self.text = text
    }

    func pasteboard(
        _: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        Thread.sleep(forTimeInterval: delay)
        item.setString(text, forType: type)
    }

    func pasteboardFinishedWithDataProvider(_: NSPasteboard) {}
}
