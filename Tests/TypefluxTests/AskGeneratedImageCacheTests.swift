import Foundation
import XCTest
@testable import Typeflux

final class AskGeneratedImageCacheTests: XCTestCase {
    func testDiskPersistenceAccountIsolationAndClearRejectsOldWriters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AskGeneratedImageCache(root: root)
        let original = try await cache.lookup(owner: "account-a", asset: "image")
        try await cache.store(Data([1, 2, 3]), ticket: original)
        let reopened = AskGeneratedImageCache(root: root)
        let hit = try await reopened.lookup(owner: "account-a", asset: "image")
        XCTAssertEqual(hit.data, Data([1, 2, 3]))
        let foreign = try await reopened.lookup(owner: "account-b", asset: "image")
        XCTAssertNil(foreign.data)
        try await reopened.clear()
        try await cache.store(Data([4]), ticket: original)
        let size = try await cache.size()
        XCTAssertEqual(size, 0)
        let fresh = try await cache.lookup(owner: "account-a", asset: "image")
        try await cache.store(Data([5]), ticket: fresh)
        XCTAssertFalse(fresh.key.contains("account-a"))
        let forced = try await cache.lookup(owner: "account-a", asset: "image", force: true)
        XCTAssertNil(forced.data)
    }

    func testEvictionBoundsBytesAndOversizedEntriesAreNotSaved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AskGeneratedImageCache(root: root, capacity: 6)
        let first = try await cache.lookup(owner: "a", asset: "one")
        try await cache.store(Data([1, 2, 3, 4]), ticket: first)
        let second = try await cache.lookup(owner: "a", asset: "two")
        try await cache.store(Data([5, 6, 7, 8]), ticket: second)
        let size = try await cache.size()
        XCTAssertEqual(size, 4)
        let last = try await cache.lookup(owner: "a", asset: "two")
        XCTAssertEqual(last.data, Data([5, 6, 7, 8]))
        try await cache.store(Data(repeating: 0, count: 7), ticket: first)
        let after = try await cache.size()
        XCTAssertEqual(after, 4)
        try await cache.remove(last)
        let empty = try await cache.size()
        XCTAssertEqual(empty, 0)
    }
}
