import Darwin
import Foundation
import XCTest
@testable import Typeflux

final class AskRecoveryProcessTests: XCTestCase {
    private static let fixtureKey = "TYPEFLUX_R04_CRASH_FIXTURE"

    func testSIGKILLAfterClaimAndReceiptRetainsOriginalJournal() async throws {
        for hasReceipt in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let child = Process()
            child.executableURL = try XCTUnwrap(Bundle.main.executableURL)
            child.arguments = ["-XCTest", "TypefluxTests.AskRecoveryProcessTests/testCrashFixtureWriter",
                               Bundle(for: Self.self).bundleURL.path]
            var environment = ProcessInfo.processInfo.environment
            environment[Self.fixtureKey] = directory.path
            environment["TYPEFLUX_R04_CRASH_RECEIPT"] = hasReceipt ? "1" : "0"
            // A killed fixture must not share the parent's coverage output.
            environment["LLVM_PROFILE_FILE"] = directory.appendingPathComponent("child-%p.profraw").path
            child.environment = environment
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            defer {
                if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }
            let ready = directory.appendingPathComponent("ready")
            let deadline = Date().addingTimeInterval(20)
            while !FileManager.default.fileExists(atPath: ready.path), child.isRunning, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "Crash fixture did not commit")
            guard child.isRunning, FileManager.default.fileExists(atPath: ready.path) else { continue }
            XCTAssertEqual(Darwin.kill(child.processIdentifier, SIGKILL), 0)
            child.waitUntilExit()
            XCTAssertEqual(child.terminationReason, .uncaughtSignal)
            XCTAssertEqual(child.terminationStatus, SIGKILL)

            let cache = try AskConversationCache(url: directory.appendingPathComponent("cache.sqlite"))
            let value = AskRecoveryFixture.conversation(), audit = AskRecoveryFixture.audit(value)
            let entry = try await cache.execution(id: audit.identity.key, owner: "owner")
            XCTAssertEqual(entry?.audit?.identity, audit.identity)
            XCTAssertEqual(entry?.receipt, hasReceipt ? AskRecoveryFixture.receipt(value) : nil)
            XCTAssertEqual(entry?.unknown, !hasReceipt)
            let claimedAgain = try await cache.claimExecution(audit, owner: "owner")
            XCTAssertFalse(claimedAgain, "A process restart cannot authorize another dispatch")
        }
    }

    /// Only a filtered child invocation enters this fixture. The parent owns its PID.
    func testCrashFixtureWriter() async throws {
        guard let path = ProcessInfo.processInfo.environment[Self.fixtureKey] else { return }
        let directory = URL(fileURLWithPath: path)
        let cache = try AskConversationCache(url: directory.appendingPathComponent("cache.sqlite"))
        let value = AskRecoveryFixture.conversation(), audit = AskRecoveryFixture.audit(value)
        let claimed = try await cache.claimExecution(audit, owner: "owner")
        XCTAssertTrue(claimed)
        if ProcessInfo.processInfo.environment["TYPEFLUX_R04_CRASH_RECEIPT"] == "1" {
            try await cache.saveReceipt(AskRecoveryFixture.receipt(value), identity: audit.identity, owner: "owner")
        }
        try Data("committed".utf8).write(to: directory.appendingPathComponent("ready"), options: .atomic)
        while true { try await Task.sleep(for: .seconds(1)) }
    }
}
