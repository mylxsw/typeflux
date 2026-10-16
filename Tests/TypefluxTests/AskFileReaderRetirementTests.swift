import Darwin
import Foundation
import XCTest
@testable import Typeflux

final class AskFileReaderRetirementTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")
    private let answer = "while IFS= read -r line; do printf '{\"entries\":[],\"path\":\"/synthetic\"}\\n'; done"
    private func wait(_ condition: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(condition())
    }
    func testLineageWaitsForHostAndCollectionAndIgnoresOldCompletion() throws {
        let owner = AskFileReaderOwnership(), id = try owner.reserve { false }
        try owner.begin(id); owner.reaped(id)
        XCTAssertTrue(owner.isOccupied)
        XCTAssertThrowsError(try owner.begin(id))
        XCTAssertThrowsError(try owner.reserve { true })
        owner.end(id); XCTAssertFalse(owner.isOccupied)
        let next = try owner.reserve { false }
        owner.reaped(id); owner.end(id); XCTAssertTrue(owner.isOccupied)
        owner.reaped(next); XCTAssertFalse(owner.isOccupied)
    }
    func testDelayedCollectionBlocksReplacementButNotIndependentOwner() throws {
        let owner = AskFileReaderOwnership()
        // The injected collector deliberately retains even a killed child.
        let flag = ReaderCollectionFlag()
        let reaper = OwnedProcessReaper(schedulesReaping: false, reaped: { pid in
            guard flag.allowed else { return false }
            var status: Int32 = 0
            return waitpid(pid, &status, WNOHANG) == pid
        })
        defer { flag.allow(); try? wait { reaper.collectPending(); return !owner.isOccupied } }
        let first = AskFileReader(executable: shell, arguments: ["-c", answer], ownership: owner, reaper: reaper)
        XCTAssertEqual(try first.resolve("/private", blocked: []), "/synthetic")
        first.stop(); XCTAssertTrue(owner.isOccupied)
        let replacement = AskFileReader(executable: shell, arguments: ["-c", answer], ownership: owner)
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try replacement.resolve("/private", blocked: []))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.6)
        let independent = AskFileReader(executable: shell, arguments: ["-c", answer])
        XCTAssertEqual(try independent.resolve("/private", blocked: []), "/synthetic"); independent.stop()
    }
    func testReleasableCollectorRetainsSlotUntilActualWaitpid() throws {
        let flag = ReaderCollectionFlag(), owner = AskFileReaderOwnership()
        let reaper = OwnedProcessReaper(schedulesReaping: false, reaped: { pid in
            flag.record(pid)
            guard flag.allowed else { return false }
            var status: Int32 = 0
            return waitpid(pid, &status, WNOHANG) == pid
        })
        let reader = AskFileReader(executable: shell, arguments: ["-c", answer], ownership: owner, reaper: reaper)
        XCTAssertEqual(try reader.resolve("/private", blocked: []), "/synthetic")
        reader.stop(); reader.stop(); XCTAssertTrue(owner.isOccupied)
        flag.allow()
        try wait { reaper.collectPending(); return !owner.isOccupied }
        XCTAssertEqual(kill(flag.pid, 0), -1)
        let next = AskFileReader(executable: shell, arguments: ["-c", answer], ownership: owner)
        XCTAssertEqual(try next.resolve("/private", blocked: []), "/synthetic"); next.stop()
        try wait { !owner.isOccupied }
    }
    func testCallbackRetainsAdmissionAfterStopAndChildCollectionWithoutBlockingReaper() throws {
        let owner = AskFileReaderOwnership()
        let reader = AskFileReader(executable: shell, arguments: ["-c", answer], ownership: owner)
        let next = AskFileReader(executable: shell, arguments: ["-c", answer], ownership: owner)
        XCTAssertThrowsError(try reader.stream(.init(operation: .resolve, path: "/private")) { _ in
            do { _ = try reader.resolve("/nested", blocked: []); XCTFail("Reentrant read admitted") } catch {}
            reader.stop()
            Thread.sleep(forTimeInterval: 0.15) // Child collection cannot release a running consumer.
            XCTAssertTrue(owner.isOccupied)
            do { _ = try next.resolve("/private", blocked: []); XCTFail("Occupied replacement admitted") } catch {}
            return true // The stopped generation must not publish successful completion.
        })
        try wait { !owner.isOccupied }
        XCTAssertEqual(try next.resolve("/private", blocked: []), "/synthetic"); next.stop()
        try wait { !owner.isOccupied }
    }
    func testEarlyConsumerStopCancellationAndLaunchFailuresReleaseOnlyTheirOwnership() throws {
        let owner = AskFileReaderOwnership()
        for args in [["-c", answer], ["-c", "exit 3"]] {
            let reader = AskFileReader(executable: shell, arguments: args, ownership: owner)
            XCTAssertThrowsError(try reader.read(.init(operation: .resolve, path: ""), isCancelled: { true }))
            XCTAssertFalse(owner.isOccupied)
        }
        for executable in ["/nonexistent/gul399-helper", "/dev/null"] {
            let reader = AskFileReader(executable: URL(fileURLWithPath: executable), ownership: owner)
            XCTAssertThrowsError(try reader.resolve("/private", blocked: [])); XCTAssertFalse(owner.isOccupied)
        }
        let invalid = AskFileReader(executable: shell, arguments: ["bad\0argument"], ownership: owner)
        XCTAssertThrowsError(try invalid.resolve("/private", blocked: [])); XCTAssertFalse(owner.isOccupied)
        let saturated = AskFileReader(executable: shell, ownership: owner, reaper: OwnedProcessReaper(capacity: 0))
        XCTAssertThrowsError(try saturated.resolve("/private", blocked: [])); XCTAssertFalse(owner.isOccupied)
        let reader = AskFileReader(executable: shell, arguments: ["-c", answer], ownership: owner)
        try reader.stream(.init(operation: .resolve, path: "")) { _ in false }
        try wait { !owner.isOccupied }
        XCTAssertEqual(try reader.resolve("/private", blocked: []), "/synthetic"); reader.stop()
        try wait { !owner.isOccupied }
    }
    func testInvalidFramesCrashAndStallDoNotLeakChildReservations() throws {
        for script in ["read line; printf 'invalid\\n'", "read line; printf '{'", "read line; ulimit -c 0; kill -ABRT $$",
                       "read line; exec /bin/sleep 20", "read line; exec /usr/bin/head -c 8388609 /dev/zero"] {
            let owner = AskFileReaderOwnership()
            let reader = AskFileReader(executable: shell, arguments: ["-c", script], timeout: 0.2, ownership: owner)
            XCTAssertThrowsError(try reader.resolve("/private", blocked: []))
            XCTAssertFalse(reader.isRunning); try wait { !owner.isOccupied }
        }
    }
    func testPriorityAndHealthyReuseKeepOneChildUntilExplicitStop() throws {
        for quality: QualityOfService in [.background, .utility, .userInitiated, .userInteractive, .default] {
            let owner = AskFileReaderOwnership()
            let reader = AskFileReader(executable: shell, arguments: ["-c", answer], qualityOfService: quality, ownership: owner)
            XCTAssertFalse(reader.isRunning)
            for _ in 0..<3 { XCTAssertEqual(try reader.resolve("/private", blocked: []), "/synthetic") }
            XCTAssertTrue(reader.isRunning); reader.stop(); try wait { !owner.isOccupied }
        }
    }
    func testLostPIDOwnershipDoesNotAuthorizeAnotherSignal() throws {
        let input = Pipe(), output = Pipe(), owner = AskFileReaderOwnership()
        let child = try AskFileReaderProcess(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
            input: input.fileHandleForReading.fileDescriptor, output: output.fileHandleForWriting.fileDescriptor,
            qualityOfService: nil, ownership: owner, reaper: .shared, isCancelled: { false })
        var status: Int32 = 0
        var collected = false
        try wait {
            if !collected { collected = waitpid(child.pid, &status, WNOHANG) == child.pid }
            return collected
        }
        XCTAssertFalse(child.isRunning)
        child.stop(); child.stop(); XCTAssertFalse(owner.isOccupied)
    }
    func testStopKillsOwnedDescendantBeforeReleasingLeaderIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("should-not-appear")
        let script = "read line; (/bin/sleep 0.4; /usr/bin/touch \"$1\") & printf '{\"entries\":[]}\\n'; wait"
        let owner = AskFileReaderOwnership(), reader = AskFileReader(executable: shell,
            arguments: ["-c", script, "descendant", marker.path], ownership: owner)
        _ = try reader.read(.init(operation: .resolve, path: "/private")); reader.stop()
        try wait { !owner.isOccupied }; Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}

private final class ReaderCollectionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var process: pid_t = 0
    var allowed: Bool { lock.withLock { value } }
    var pid: pid_t { lock.withLock { process } }
    func allow() { lock.withLock { value = true } }
    func record(_ pid: pid_t) { lock.withLock { process = pid } }
}
