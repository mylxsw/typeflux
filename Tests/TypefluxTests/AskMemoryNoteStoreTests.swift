import Foundation
@testable import Typeflux
import XCTest

final class AskMemoryNoteStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-memory-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testFirstRememberFailureReallyRetriesBeforeDeduplicating() throws {
        for failure in FailingMemoryNoteFileStorage.Failure.allCases {
            let file = root.appendingPathComponent("\(failure).json")
            let storage = FailingMemoryNoteFileStorage()
            let store = AskMemoryNoteStore(fileURL: file, storage: storage)
            storage.failure = failure

            for _ in 0 ..< 2 {
                XCTAssertThrowsError(try store.execute(["action": "remember", "text": "Prefers metric units"], owner: "a")) {
                    XCTAssertEqual($0 as? FailingMemoryNoteFileStorage.Failure, failure)
                }
                XCTAssertTrue(store.list(owner: "a").isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
                XCTAssertTrue(AskMemoryNoteStore(fileURL: file).list(owner: "a").isEmpty)
            }
            XCTAssertEqual(storage.writeAttempts, 2)
            storage.failure = nil
            let note = try store.add("Prefers metric units", owner: "a")
            XCTAssertEqual(storage.writeAttempts, 3)
            XCTAssertEqual(AskMemoryNoteStore(fileURL: file).list(owner: "a"), [note])
            XCTAssertEqual(try store.add(" prefers METRIC units ", owner: "a"), note)
            XCTAssertEqual(storage.writeAttempts, 3)
        }
    }

    func testFailedRememberPreservesExistingOwnersAndDisk() throws {
        for failure in FailingMemoryNoteFileStorage.Failure.allCases {
            let file = root.appendingPathComponent("\(failure).json")
            let storage = FailingMemoryNoteFileStorage()
            let store = AskMemoryNoteStore(fileURL: file, storage: storage)
            let first = try store.add("First fact", owner: "a")
            let other = try store.add("Other account", owner: "b")
            let original = try Data(contentsOf: file)
            storage.failure = failure
            XCTAssertThrowsError(try store.add("Second fact", owner: "a"))
            XCTAssertEqual(store.list(owner: "a"), [first])
            XCTAssertEqual(store.list(owner: "b"), [other])
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertEqual(AskMemoryNoteStore(fileURL: file).list(owner: "a"), [first])

            storage.failure = nil
            let second = try store.add("Second fact", owner: "a")
            let restarted = AskMemoryNoteStore(fileURL: file)
            XCTAssertEqual(restarted.list(owner: "a"), [first, second])
            XCTAssertEqual(restarted.list(owner: "b"), [other])
        }
    }

    func testForgetFailureKeepsTheNoteAndRetryRemovesItDurably() throws {
        for failure in FailingMemoryNoteFileStorage.Failure.allCases {
            let file = root.appendingPathComponent("\(failure).json")
            let storage = FailingMemoryNoteFileStorage()
            let store = AskMemoryNoteStore(fileURL: file, storage: storage)
            let note = try store.add("Remove me", owner: "a")
            let retained = try store.add("Keep me", owner: "a")
            let other = try store.add("Other account", owner: "b")
            let original = try Data(contentsOf: file)
            storage.failure = failure

            for _ in 0 ..< 2 {
                XCTAssertThrowsError(try store.execute(["action": "forget", "id": note.id], owner: "a")) {
                    XCTAssertEqual($0 as? FailingMemoryNoteFileStorage.Failure, failure)
                }
                XCTAssertEqual(store.list(owner: "a"), [note, retained])
                XCTAssertEqual(store.list(owner: "b"), [other])
                XCTAssertEqual(try Data(contentsOf: file), original)
                XCTAssertEqual(AskMemoryNoteStore(fileURL: file).list(owner: "a"), [note, retained])
            }
            XCTAssertEqual(storage.writeAttempts, 5)
            storage.failure = nil
            XCTAssertEqual(try store.execute(["action": "forget", "id": note.id], owner: "a"), "Forgot note \(note.id).")
            XCTAssertEqual(storage.writeAttempts, 6)
            let restarted = AskMemoryNoteStore(fileURL: file)
            XCTAssertEqual(store.list(owner: "a"), [retained])
            XCTAssertEqual(restarted.list(owner: "a"), [retained])
            XCTAssertEqual(restarted.list(owner: "b"), [other])
        }
    }

    func testClearFailurePreservesEveryOwnerAndRetryClearsOnlyTheOwner() throws {
        for failure in FailingMemoryNoteFileStorage.Failure.allCases {
            let file = root.appendingPathComponent("\(failure).json")
            let storage = FailingMemoryNoteFileStorage()
            let store = AskMemoryNoteStore(fileURL: file, storage: storage)
            let note = try store.add("Keep until committed", owner: "a")
            let other = try store.add("Other account", owner: "b")
            let original = try Data(contentsOf: file)
            storage.failure = failure

            for _ in 0 ..< 2 {
                XCTAssertThrowsError(try store.clear(owner: "a")) {
                    XCTAssertEqual($0 as? FailingMemoryNoteFileStorage.Failure, failure)
                }
                XCTAssertEqual(store.list(owner: "a"), [note])
                XCTAssertEqual(store.list(owner: "b"), [other])
                XCTAssertEqual(try Data(contentsOf: file), original)
                XCTAssertEqual(AskMemoryNoteStore(fileURL: file).list(owner: "a"), [note])
            }
            XCTAssertEqual(storage.writeAttempts, 4)
            storage.failure = nil
            try store.clear(owner: "a")
            XCTAssertEqual(storage.writeAttempts, 5)
            let restarted = AskMemoryNoteStore(fileURL: file)
            XCTAssertTrue(store.list(owner: "a").isEmpty)
            XCTAssertTrue(restarted.list(owner: "a").isEmpty)
            XCTAssertEqual(restarted.list(owner: "b"), [other])
        }
    }

    func testReadsLegacyJSONAndPreservesIDsDatesAndOwnerIsolation() throws {
        let file = root.appendingPathComponent("legacy.json")
        let json = #"{"a":[{"id":"deadbeef","text":"Legacy note","createdAt":12345}],"b":[{"id":"abcdef01","text":"Private note","createdAt":67890}]}"#
        try Data(json.utf8).write(to: file)
        let store = AskMemoryNoteStore(fileURL: file)
        let expected = AskMemoryNote(id: "deadbeef", text: "Legacy note", createdAt: Date(timeIntervalSinceReferenceDate: 12345))
        XCTAssertEqual(store.list(owner: "a"), [expected])
        XCTAssertFalse(try store.remove(id: "deadbeef", owner: "b"))
        XCTAssertEqual(try store.add("LEGACY NOTE", owner: "a"), expected)
        let independent = try store.add("Legacy note", owner: "b")
        XCTAssertNotEqual(independent.id, expected.id)
        let restarted = AskMemoryNoteStore(fileURL: file)
        XCTAssertEqual(restarted.list(owner: "a"), [expected])
        XCTAssertEqual(restarted.list(owner: "b").first?.createdAt, Date(timeIntervalSinceReferenceDate: 67890))
        XCTAssertEqual(restarted.list(owner: "b").last, independent)
    }

    func testDirectoryCreationFailureDoesNotPublishAndCanBeRetried() throws {
        let parent = root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: parent)
        let file = parent.appendingPathComponent("notes.json")
        let store = AskMemoryNoteStore(fileURL: file)
        XCTAssertThrowsError(try store.add("Retry me", owner: "a"))
        XCTAssertTrue(store.list(owner: "a").isEmpty)
        try FileManager.default.removeItem(at: parent)
        let note = try store.add("Retry me", owner: "a")
        XCTAssertEqual(AskMemoryNoteStore(fileURL: file).list(owner: "a"), [note])
    }

    func testConcurrentMutationsDoNotLoseCommittedNotes() throws {
        let file = root.appendingPathComponent("concurrent.json")
        let store = AskMemoryNoteStore(fileURL: file)
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            do { try store.add("Note \(index)", owner: index.isMultiple(of: 2) ? "a" : "b") }
            catch { XCTFail("Unexpected persistence failure: \(error)") }
        }
        let restarted = AskMemoryNoteStore(fileURL: file)
        for owner in ["a", "b"] {
            XCTAssertEqual(store.list(owner: owner).count, 20)
            XCTAssertEqual(Set(store.list(owner: owner).map(\.text)).count, 20)
            XCTAssertEqual(restarted.list(owner: owner), store.list(owner: owner))
        }
    }
}

/// Models an atomic file writer failing during staging or before replacing its
/// destination. Successful commits use the production adapter and real files.
final class FailingMemoryNoteFileStorage: AskMemoryNoteFileStorage {
    enum Failure: String, Error, LocalizedError, CaseIterable {
        case write, replace
        var errorDescription: String? { "Injected memory note \(rawValue) failure." }
    }

    var failure: Failure?
    private(set) var writeAttempts = 0
    private let storage = LocalAskMemoryNoteFileStorage()

    func read(from url: URL) throws -> Data { try storage.read(from: url) }

    func writeAtomically(_ data: Data, to url: URL) throws {
        writeAttempts += 1
        if let failure {
            let staging = url.deletingLastPathComponent().appendingPathComponent("staging-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            // A failed staging write may have written only a prefix; a failed
            // replacement leaves a complete candidate but the old destination.
            try (failure == .write ? Data(data.prefix(8)) : data).write(to: staging)
            throw failure
        }
        try storage.writeAtomically(data, to: url)
    }
}
