import AppKit
import Darwin
import XCTest
@testable import Typeflux

private final class PublicationGate: @unchecked Sendable {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func wait() { lock.withLock { calls += 1 }; gate.wait() }
}
private actor PublicationExporter: ScreenRecordingExporting {
    var pending: CheckedContinuation<Void, Never>?
    var calls = 0
    var fail = false
    func export(source _: URL, destination: URL, format _: ScreenRecordingFormat, trim _: ScreenRecordingTrim,
                progress: @escaping @Sendable (Double) -> Void) async throws {
        calls += 1
        try Data([4, 5, 6]).write(to: destination)
        for i in 0..<10_000 { progress(Double(i) / 10_000) }
        await withCheckedContinuation { pending = $0 }
        if fail { throw CocoaError(.fileWriteOutOfSpace) }
    }
    var ready: Bool { pending != nil }
    func resolve(fail: Bool = false) { self.fail = fail; pending?.resume(); pending = nil }
}

@MainActor final class RecordingPublicationIsolationTests: XCTestCase {
    private struct Fixture {
        let root: URL, source: URL, destination: URL, files: ScreenRecordingFiles
        init() throws {
            root = try AskAttachmentFixture.directory()
            files = ScreenRecordingFiles(root: root.appendingPathComponent("sessions"))
            let session = try files.createSession(options: .init())
            source = session.appendingPathComponent("result.mp4")
            try Data([1, 2, 3]).write(to: source)
            try Data([7, 8, 9]).write(to: session.appendingPathComponent("source.mov"))
            destination = root.appendingPathComponent("saved")
        }
        func prepare(rename: @escaping ScreenRecordingPublication.Rename = { try ScreenRecordingPublication.renameFile($0, $1, $2, $3) },
                     gate: @escaping @Sendable () -> Void = {}) async throws -> ScreenRecordingPublication {
            try await ScreenRecordingPublication.prepare(source: source, directory: destination, format: .mp4,
                name: "Result", destination: nil, protectedRoot: files.root, rename: rename, beforeCopy: gate)
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
    private func receipt(_ publication: ScreenRecordingPublication) throws -> ScreenRecordingPublication.Receipt {
        try JSONDecoder().decode(ScreenRecordingPublication.Receipt.self, from: Data(contentsOf: publication.receiptURL))
    }
    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Publication did not settle")
    }
    func testPreparedBytesCommitOnceAndPersistIdentityWithoutDeletingOriginal() async throws {
        let f = try Fixture(); defer { f.clean() }
        let p = try await f.prepare()
        XCTAssertTrue(p.mayDiscardSession); XCTAssertEqual(try receipt(p).phase, .prepared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.destination.path))
        let result = try p.commit { true }
        XCTAssertEqual(try Data(contentsOf: result), Data([1, 2, 3]))
        let saved = try receipt(p)
        XCTAssertEqual(saved.phase, .published); XCTAssertEqual(saved.bytes, 3)
        XCTAssertEqual(saved.source, "result.mp4"); XCTAssertEqual(saved.destination, result.path)
        XCTAssertThrowsError(try p.commit { XCTFail("Duplicate reached authorization"); return true })
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: result.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testRevocationBeforeCommitLeavesDestinationUntouchedAndCleansOnlyPrivateStage() async throws {
        let f = try Fixture(); defer { f.clean() }
        var p: ScreenRecordingPublication? = try await f.prepare()
        let target = try XCTUnwrap(p).destination, journal = try XCTUnwrap(p).receiptURL
        XCTAssertThrowsError(try p!.commit { false })
        XCTAssertEqual(try receipt(p!).phase, .cancelled)
        p = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }
    func testChangedSourceStageDestinationAndPinnedDirectoryRejectCommit() async throws {
        for kind in 0..<4 {
            let f = try Fixture(); defer { f.clean() }
            let p = try await f.prepare()
            switch kind {
            case 0: try Data([9, 8]).write(to: f.source)
            case 1:
                let stage = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: f.destination.path).first)
                try Data([9]).write(to: f.destination.appendingPathComponent(stage))
            case 2: try Data([9]).write(to: p.destination)
            default: try FileManager.default.moveItem(at: f.destination, to: f.root.appendingPathComponent("moved"))
            }
            XCTAssertThrowsError(try p.commit { XCTFail("Changed identity reached authorization"); return true })
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
        }
    }
    func testUnknownRenameBeforeOrAfterEffectKeepsReceiptAndNeverRetries() async throws {
        for didRename in [false, true] {
            let f = try Fixture(); defer { f.clean() }
            let p = try await f.prepare(rename: { fd, source, target, replace in
                if didRename { try ScreenRecordingPublication.renameFile(fd, source, target, replace) }
                throw CocoaError(.fileWriteUnknown)
            })
            XCTAssertThrowsError(try p.commit { true }) { error in
                XCTAssertEqual(error.localizedDescription, L("recording.publicationUnknown"))
            }
            XCTAssertEqual(try receipt(p).phase, .unknown)
            XCTAssertEqual(FileManager.default.fileExists(atPath: p.destination.path), didRename)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
            XCTAssertThrowsError(try p.commit { true })
            let next = try await f.prepare(); XCTAssertFalse(next.mayDiscardSession)
        }
    }
    func testSparseOversizeLinksProtectedDestinationsAndMalformedTargetsFailBeforeCopy() async throws {
        let f = try Fixture(); defer { f.clean() }
        let fd = open(f.source.path, O_WRONLY); XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, off_t(ScreenRecordingPublication.maximumBytes + 1)), 0); close(fd)
        do { _ = try await f.prepare(); XCTFail("Oversize accepted") } catch {}
        try FileManager.default.removeItem(at: f.source)
        try FileManager.default.createSymbolicLink(at: f.source, withDestinationURL: f.source.deletingLastPathComponent().appendingPathComponent("source.mov"))
        do { _ = try await f.prepare(); XCTFail("Symlink accepted") } catch {}
        try FileManager.default.removeItem(at: f.source); try Data([1]).write(to: f.source)
        for dir in [f.files.root, f.files.root.appendingPathComponent("child")] {
            do { _ = try await f.files.preparePublication(f.source, in: dir, format: .mp4); XCTFail("Session destination accepted") } catch {}
        }
        try FileManager.default.createDirectory(at: f.destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.destination.appendingPathComponent("Result.mp4"), withDestinationURL: f.source)
        do { _ = try await f.prepare(); XCTFail("Linked target accepted") } catch {}
        do { _ = try await ScreenRecordingPublication.prepare(source: f.source, directory: URL(string: "https://example.invalid")!, format: .mp4, name: nil, destination: nil, protectedRoot: f.files.root); XCTFail("Remote destination accepted") } catch {}
    }
    func testReceiptQuotaAndEarlierPartialOutputPreventDestructiveSuccessCleanup() async throws {
        let f = try Fixture(); defer { f.clean() }
        let folder = f.source.deletingLastPathComponent()
        try Data([99]).write(to: folder.appendingPathComponent("earlier-partial.gif"))
        do { let p = try await f.prepare(); XCTAssertFalse(p.mayDiscardSession) }
        for i in 0..<16 { try Data([1]).write(to: folder.appendingPathComponent(".publication-\(i).json")) }
        do { _ = try await f.prepare(); XCTFail("Receipt quota accepted") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("earlier-partial.gif").path))
    }
    func testCancelledUncooperativePreparationRetainsBothAdmissionsUntilCompletion() async throws {
        let f = try Fixture(); defer { f.clean() }
        let gate = PublicationGate()
        let first = Task { try await f.prepare(gate: { gate.wait() }) }
        let second = Task { try await f.prepare(gate: { gate.wait() }) }
        try await wait { gate.count == 2 }
        first.cancel(); second.cancel()
        do { _ = try await f.prepare(); XCTFail("Cancelled host work released admission early") } catch {}
        let cancelled = Task { try await f.prepare(gate: { XCTFail("Cancelled task dispatched copy") }) }
        cancelled.cancel(); _ = await cancelled.result
        gate.gate.signal(); gate.gate.signal()
        do { _ = try await first.value; XCTFail("Cancelled result returned") } catch {}
        do { _ = try await second.value; XCTFail("Cancelled result returned") } catch {}
        let p = try await f.prepare(); XCTAssertEqual(try receipt(p).phase, .prepared)
    }
    func testCancelledPreparedCommitDoesNotAuthorizeOrPublish() async throws {
        let f = try Fixture(); defer { f.clean() }; let p = try await f.prepare()
        let task = Task { try p.commit { XCTFail("Cancelled commit authorized"); return true } }
        task.cancel(); do { _ = try await task.value; XCTFail("Cancelled commit succeeded") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.destination.path))
    }
    func testProgressIsFiniteMonotonicAndCoalesced() {
        let progress = ScreenRecordingProgressBuffer()
        for value in [-1, .nan, .infinity, 0.7, 0.2, 2] { progress.offer(value) }
        XCTAssertEqual(progress.latest, 1)
    }
    func testCoordinatorRejectsDuplicateAndRevokedLateExportWithoutCopyOrSourceDeletion() async throws {
        let exporter = PublicationExporter(), fixture = ScreenRecordingCoordinatorTests.Fixture(exporter: exporter)
        fixture.model.loadTimeline = { _ in .init() }
        await fixture.recording(); fixture.model.stop(); await fixture.model.pendingTask?.value
        let source = try XCTUnwrap(fixture.model.sourceURL)
        fixture.model.export(copy: true); fixture.model.export(copy: true)
        try await wait { await exporter.ready }
        fixture.model.retirePreview(); await exporter.resolve()
        await fixture.model.pendingTask?.value
        let count = await exporter.calls; XCTAssertEqual(count, 1)
        XCTAssertNil(fixture.model.savedURL); XCTAssertNil(fixture.copiedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let retained = try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path)
        XCTAssertTrue(retained.contains { $0.hasSuffix(".mp4") })
        await fixture.clean()
    }
    func testCoordinatorPartialFailureAndSourceMutationNeverPublish() async throws {
        for failure in [true, false] {
            let exporter = PublicationExporter(), fixture = ScreenRecordingCoordinatorTests.Fixture(exporter: exporter)
            fixture.model.loadTimeline = { _ in .init() }
            await fixture.recording(); fixture.model.stop(); await fixture.model.pendingTask?.value
            let source = try XCTUnwrap(fixture.model.sourceURL)
            fixture.model.export(copy: true); try await wait { await exporter.ready }
            if !failure { try Data([99]).write(to: source) }
            await exporter.resolve(fail: failure); await fixture.model.pendingTask?.value
            XCTAssertEqual(fixture.model.state, .preview); XCTAssertNotNil(fixture.model.error)
            XCTAssertNil(fixture.model.savedURL); XCTAssertNil(fixture.copiedURL)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path).contains { $0.hasSuffix(".mp4") })
            await fixture.clean()
        }
    }
    func testSuccessfulLaterExportRetainsEarlierFailedOutputAndOriginal() async throws {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        fixture.model.loadTimeline = { _ in .init() }
        await fixture.recording(); fixture.model.stop(); await fixture.model.pendingTask?.value
        let source = try XCTUnwrap(fixture.model.sourceURL)
        let earlier = source.deletingLastPathComponent().appendingPathComponent("old-partial.mp4")
        try Data([22]).write(to: earlier)
        fixture.model.export(); await fixture.model.pendingTask?.value
        XCTAssertEqual(fixture.model.state, .completed); XCTAssertNotNil(fixture.model.savedURL)
        XCTAssertEqual(try Data(contentsOf: earlier), Data([22])); XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        await fixture.clean()
    }
    func testAccountRevocationAndOwnerReleaseFenceUncooperativeEncoder() async throws {
        for release in [false, true] {
            let exporter = PublicationExporter()
            var fixture: ScreenRecordingCoordinatorTests.Fixture? = .init(exporter: exporter)
            fixture!.model.loadTimeline = { _ in .init() }
            await fixture!.recording(); fixture!.model.stop(); await fixture!.model.pendingTask?.value
            let source = try XCTUnwrap(fixture!.model.sourceURL), root = fixture!.root, suite = fixture!.suite
            weak var model = fixture!.model
            fixture!.model.export(copy: true); let task = fixture!.model.pendingTask
            try await wait { await exporter.ready }
            if release { fixture = nil; XCTAssertNil(model) }
            else { NotificationCenter.default.post(name: .authDidLogout, object: nil) }
            await exporter.resolve(); await task?.value
            XCTAssertNil(model?.savedURL); XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            if let fixture { await fixture.clean() }
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

}
