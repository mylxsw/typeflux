import AppKit
import TypefluxMediaProtocol
import XCTest
@testable import Typeflux

private final class CopyActionsFixture: ClipboardContentActing {
    var preparation: () async throws -> AskWorkflowImage.Clipboard? = { nil }
    var writes = 0, pastes = 0, prepares = 0
    var succeeds = true
    var pasteboardRevision: Int? = 1
    func prepareImage(_ entry: ClipboardEntry) async throws -> AskWorkflowImage.Clipboard? {
        prepares += 1; return try await preparation()
    }
    func writeToPasteboard(_ entry: ClipboardEntry, asPlainText: Bool, image: AskWorkflowImage.Clipboard?) -> Bool {
        writes += 1; return succeeds
    }
    func sendPasteShortcut() { pastes += 1 }
    func revealInFinder(_ urls: [URL]) {}
    func saveToDownloads(_ url: URL) -> URL? { nil }
    func recognizeText(in imageURL: URL) async -> String? { nil }
}

@MainActor final class ClipboardCopyIsolationTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Action did not complete")
    }
    private let entry = ClipboardTestSupport.entry(.image, imagePath: "/synthetic")

    func testDuplicateActionAndCancellationRetainAdmissionUntilPreparationFinishes() async throws {
        let action = ClipboardContentAction(), sink = CopyActionsFixture()
        var resume: CheckedContinuation<Void, Never>?
        sink.preparation = { await withCheckedContinuation { resume = $0 }; return nil }
        XCTAssertTrue(action.start(entry: entry, plainText: false, paste: true, actions: sink, authorized: { true }))
        try await wait { resume != nil }
        action.cancel()
        XCTAssertFalse(action.start(entry: entry, plainText: false, paste: true, actions: sink, authorized: { true }))
        resume?.resume(); try await wait { !action.isRunning }
        XCTAssertEqual(sink.prepares, 1); XCTAssertEqual(sink.writes, 0); XCTAssertEqual(sink.pastes, 0)
    }

    func testDeletionOrRevocationAfterAwaitNeverWrites() async throws {
        for revokeAccount in [false, true] {
            let action = ClipboardContentAction(), sink = CopyActionsFixture()
            var allowed = true
            sink.preparation = {
                if revokeAccount { NotificationCenter.default.post(name: .authDidLogout, object: nil) }
                else { allowed = false }
                return nil
            }
            action.start(entry: entry, plainText: false, paste: true, actions: sink, authorized: { allowed })
            try await wait { !action.isRunning }
            XCTAssertEqual(sink.writes, 0); XCTAssertEqual(sink.pastes, 0)
        }
    }

    func testOwnerReleaseCancelsLatePreparation() async throws {
        var action: ClipboardContentAction? = ClipboardContentAction()
        let sink = CopyActionsFixture()
        var resume: CheckedContinuation<Void, Never>?
        sink.preparation = { await withCheckedContinuation { resume = $0 }; return nil }
        action?.start(entry: entry, plainText: false, paste: true, actions: sink, authorized: { true })
        try await wait { resume != nil }; weak var weakAction = action; action = nil
        XCTAssertNil(weakAction); resume?.resume()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(sink.writes, 0)
    }

    func testIntentionalDismissalAllowsOnePasteButChangedClipboardOrAccountStopsIt() async throws {
        for change in 0...2 {
            let action = ClipboardContentAction(), sink = CopyActionsFixture()
            var visible = true, failures = 0
            action.start(entry: entry, plainText: false, paste: true, actions: sink, authorized: { true },
                beforeCommit: { visible }, committed: { visible = false; action.cancelPreparation() },
                failed: { failures += 1 }, delay: {
                    if change == 1 { sink.pasteboardRevision = 2 }
                    if change == 2 { NotificationCenter.default.post(name: .authTokenDidRefresh, object: nil) }
                })
            try await wait { !action.isRunning }
            XCTAssertEqual(sink.writes, 1); XCTAssertEqual(sink.pastes, change == 0 ? 1 : 0); XCTAssertEqual(failures, 0)
        }
    }

    func testFailureIsReportedOnceWithoutPasteOrRetryAndCopyNeedsNoShortcut() async throws {
        for failure in 0...2 {
            let action = ClipboardContentAction(), sink = CopyActionsFixture()
            var failed = 0, committed = 0
            if failure == 0 { sink.preparation = { throw MediaFailure.unavailable } }
            if failure == 1 { sink.succeeds = false }
            action.start(entry: entry, plainText: false, paste: false, actions: sink, authorized: { true },
                committed: { committed += 1 }, failed: { failed += 1 })
            try await wait { !action.isRunning }
            XCTAssertEqual(failed, failure < 2 ? 1 : 0); XCTAssertEqual(committed, failure == 2 ? 1 : 0)
            XCTAssertEqual(sink.prepares, 1); XCTAssertEqual(sink.pastes, 0)
        }
    }

    func testBeforeCommitIsRecheckedAndCancelledPreparationCannotReplaceItself() async throws {
        let action = ClipboardContentAction(), sink = CopyActionsFixture()
        var visible = false
        XCTAssertFalse(action.start(entry: entry, plainText: false, paste: false, actions: sink, authorized: { true }, beforeCommit: { visible }))
        visible = true
        sink.preparation = { visible = false; action.cancelPreparation(); return nil }
        action.start(entry: entry, plainText: false, paste: false, actions: sink, authorized: { true }, beforeCommit: { visible })
        try await wait { !action.isRunning }; XCTAssertEqual(sink.writes, 0)
    }

    func testShutdownFencesPendingAndFutureActions() async throws {
        let action = ClipboardContentAction(), sink = CopyActionsFixture()
        sink.preparation = { action.preventNewWork(); return nil }
        action.start(entry: entry, plainText: false, paste: true, actions: sink, authorized: { true })
        try await wait { !action.isRunning }
        XCTAssertFalse(action.start(entry: entry, plainText: false, paste: true, actions: sink, authorized: { true }))
        XCTAssertEqual(sink.writes, 0)
    }

    func testOversizedOrRemovedFileListsNeverClearPasteboard() {
        let board = NSPasteboard(name: .init(UUID().uuidString)); defer { board.releaseGlobally() }
        board.setString("keep", forType: .string)
        let actions = SystemClipboardContentActions(pasteboard: board)
        for paths in [["/missing-private-fixture"], Array(repeating: "/fixture", count: 1001), [String(repeating: "x", count: 1_048_577)]] {
            XCTAssertFalse(actions.writeToPasteboard(ClipboardTestSupport.entry(.files, filePaths: paths), asPlainText: true, image: nil))
            XCTAssertEqual(board.string(forType: .string), "keep")
        }
    }

    func testProtocolPreservesCaptureDimensionAndRejectsNonPNGAndExcessPixels() throws {
        let request = MediaRequest(operation: .copyClipboardImage)
        var response = MediaResponse(id: request.id)
        var metadata = MediaWorkflowImage(format: .png, width: 16384, height: 1, scale: 1)
        metadata.pngBytes = 12; metadata.tiffBytes = 64
        response.workflowImage = metadata; try response.validate(for: request)
        XCTAssertThrowsError(try metadata.validate(copying: true))
        metadata.format = .jpeg; response.workflowImage = metadata
        XCTAssertThrowsError(try response.validate(for: request))
        metadata.format = .png; metadata.height = 16384; response.workflowImage = metadata
        XCTAssertThrowsError(try response.validate(for: request))
    }

    func testOriginalPNGSurvivesChildConversionAndChangedSourceCannotCommit() async throws {
        let root = ClipboardTestSupport.temporaryDirectory(), url = root.appendingPathComponent("image.png")
        defer { try? FileManager.default.removeItem(at: root) }
        let png = ClipboardTestSupport.imageData(width: 20, height: 10)
        try png.write(to: url)
        let board = NSPasteboard(name: .init(UUID().uuidString)); defer { board.releaseGlobally() }
        board.setString("untouched", forType: .string)
        let actions = SystemClipboardContentActions(pasteboard: board)
        let entry = ClipboardTestSupport.entry(.image, imagePath: url.path)
        let image = try await actions.prepareImage(entry)
        XCTAssertEqual(image?.png, png)
        XCTAssertTrue(actions.writeToPasteboard(entry, asPlainText: false, image: image))
        XCTAssertEqual(board.data(forType: .png), png); XCTAssertNotNil(board.data(forType: .tiff))
        board.clearContents(); board.setString("new content", forType: .string)
        try png.write(to: url, options: .atomic)
        XCTAssertFalse(actions.writeToPasteboard(entry, asPlainText: false, image: image))
        XCTAssertEqual(board.string(forType: .string), "new content")
    }

    func testMalformedOversizedAndSymlinkInputsLeavePrivatePasteboardUntouched() async throws {
        let root = ClipboardTestSupport.temporaryDirectory(), url = root.appendingPathComponent("image.png")
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard(name: .init(UUID().uuidString)); defer { board.releaseGlobally() }
        board.setString("keep", forType: .string)
        let actions = SystemClipboardContentActions(pasteboard: board)
        for data in [Data([1, 2]), Data(repeating: 0, count: ClipboardCaptureRules.maximumImageBytes + 1)] {
            try data.write(to: url)
            do { _ = try await actions.prepareImage(ClipboardTestSupport.entry(.image, imagePath: url.path)); XCTFail("Accepted invalid input") } catch {}
            XCTAssertEqual(board.string(forType: .string), "keep")
        }
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try ClipboardImageRevision(link))
        XCTAssertThrowsError(try ClipboardImageRevision(URL(string: "https://invalid/image")!))
    }
}
