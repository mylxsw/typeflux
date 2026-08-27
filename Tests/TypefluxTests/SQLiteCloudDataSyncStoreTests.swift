import Foundation
import Testing
@testable import Typeflux

struct SQLiteCloudDataSyncStoreTests {
    @Test func consentDefaultsOffAndIsScopedByAccount() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteCloudDataSyncStore(baseDirectory: directory)

        #expect(store.state(userID: "user-a").enabled == false)
        store.setEnabled(true, userID: "user-a")
        #expect(store.state(userID: "user-a").enabled == true)
        #expect(store.state(userID: "user-b").enabled == false)
    }

    @Test func localChangesBecomeCreateUpdateAndDeleteMutations() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteCloudDataSyncStore(baseDirectory: directory)
        let userID = "user-a"
        let entityID = UUID()
        let first = Data(#"{"term":"Typeflux"}"#.utf8)
        let second = Data(#"{"term":"Typeflux AI"}"#.utf8)

        store.stageLocalChanges(userID: userID, type: .vocabulary, entities: [entityID: first])
        let create = try #require(store.pending(userID: userID).first)
        #expect(create.operation == "create")
        #expect(create.baseRevision == 0)

        let accepted = CloudSyncMutationResult(
            mutationID: create.mutationID, status: "accepted", entityID: entityID,
            canonicalID: entityID, revision: 1, current: nil
        )
        store.accept([accepted], mutations: [create], userID: userID)
        store.stageLocalChanges(userID: userID, type: .vocabulary, entities: [entityID: second])
        let update = try #require(store.pending(userID: userID).first)
        #expect(update.operation == "update")
        #expect(update.baseRevision == 1)

        store.accept([
            CloudSyncMutationResult(
                mutationID: update.mutationID, status: "accepted", entityID: entityID,
                canonicalID: entityID, revision: 2, current: nil
            )
        ], mutations: [update], userID: userID)
        store.stageLocalChanges(userID: userID, type: .vocabulary, entities: [:])
        let delete = try #require(store.pending(userID: userID).first)
        #expect(delete.operation == "delete")
        #expect(delete.baseRevision == 2)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
