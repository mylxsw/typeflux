@testable import Typeflux
import XCTest

final class OverlayControllerTests: XCTestCase {
    @MainActor
    func testDeinitCleansUpInstalledPickerMonitoring() {
        weak var weakController: OverlayController?

        autoreleasepool {
            let controller = OverlayController(appState: AppStateStore())
            weakController = controller
            controller.showPersonaPicker(
                items: [.init(id: "test", title: "Test", subtitle: "")],
                selectedIndex: 0,
                title: "Picker",
                instructions: "Choose",
                icon: .none
            )
        }

        XCTAssertNil(weakController)
    }

    func testLiveTranscriptPreviewLayoutCapsVisibleTextToThreeLines() {
        XCTAssertEqual(LiveTranscriptPreviewLayout.maxVisibleLineCount, 3)
        XCTAssertEqual(
            LiveTranscriptPreviewLayout.textViewportHeight,
            LiveTranscriptPreviewLayout.lineHeight * 3,
            accuracy: 0.001
        )
    }

    func testExpandedRecordingPreviewLayoutIsSmallerThanPreviousFiveLineDesign() {
        XCTAssertLessThan(LiveTranscriptPreviewLayout.expandedCapsuleHeight, 127)
        XCTAssertLessThan(LiveTranscriptPreviewLayout.expandedOverlayHeight, 218)
    }

    func testWrapFailureActionsRunsDismissBeforeOriginalHandler() {
        var events: [String] = []
        let wrapped = OverlayController.wrapFailureActions(
            [
                OverlayFailureAction(
                    title: "Login",
                    isRetry: false,
                    handler: { events.append("action") }
                )
            ],
            beforeAction: { events.append("dismiss") }
        )

        XCTAssertEqual(wrapped.count, 1)

        wrapped[0].handler()

        XCTAssertEqual(events, ["dismiss", "action"])
    }

    func testWrapFailureActionsPreservesMetadata() {
        let wrapped = OverlayController.wrapFailureActions(
            [
                OverlayFailureAction(
                    title: "Retry",
                    isRetry: true,
                    style: .text,
                    trailingSystemImage: "gearshape",
                    handler: {}
                )
            ],
            beforeAction: {}
        )

        XCTAssertEqual(wrapped[0].title, "Retry")
        XCTAssertTrue(wrapped[0].isRetry)
        XCTAssertEqual(wrapped[0].style, .text)
        XCTAssertEqual(wrapped[0].trailingSystemImage, "gearshape")
    }

    func testPassiveNoticeDoesNotAcceptMouseInteraction() {
        XCTAssertFalse(OverlayController.noticeIsInteractive(dismissible: false))
        XCTAssertTrue(OverlayController.noticeIsInteractive(dismissible: true))
    }
}
