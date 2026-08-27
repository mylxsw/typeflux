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

    @Test func occurrenceOnlyChangeUsesIncrementAndStoresServerCurrent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteCloudDataSyncStore(baseDirectory: directory)
        let userID = "user-a"
        let entityID = UUID()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try encoder.encode(VocabularyCloudPayload(
            term: "Typeflux", source: "manual", createdAt: createdAt, occurrenceCount: 2
        ))
        let current = try encoder.encode(VocabularyCloudPayload(
            term: "Typeflux", source: "manual", createdAt: createdAt, occurrenceCount: 5
        ))

        store.stageLocalChanges(userID: userID, type: .vocabulary, entities: [entityID: first])
        let create = try #require(store.pending(userID: userID).first)
        store.accept([
            CloudSyncMutationResult(
                mutationID: create.mutationID, status: "accepted", entityID: entityID,
                canonicalID: entityID, revision: 1, current: JSONValue(data: first)
            )
        ], mutations: [create], userID: userID)

        store.stageLocalChanges(userID: userID, type: .vocabulary, entities: [entityID: current])
        let increment = try #require(store.pending(userID: userID).first)
        #expect(increment.operation == "increment")
        #expect(String(decoding: increment.payload, as: UTF8.self).contains("3"))
        store.accept([
            CloudSyncMutationResult(
                mutationID: increment.mutationID, status: "accepted", entityID: entityID,
                canonicalID: entityID, revision: 2, current: JSONValue(data: current)
            )
        ], mutations: [increment], userID: userID)
        #expect(store.knownEntities(userID: userID, type: .vocabulary)[entityID]?.payload == current)
    }

    @Test func acceptedCanonicalEntityUsesServerPayload() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteCloudDataSyncStore(baseDirectory: directory)
        let localID = UUID()
        let canonicalID = UUID()
        let local = Data(#"{"term":"typeflux","occurrence_count":1}"#.utf8)
        let server = Data(#"{"term":"Typeflux","occurrence_count":8}"#.utf8)
        store.stageLocalChanges(userID: "u", type: .vocabulary, entities: [localID: local])
        let mutation = try #require(store.pending(userID: "u").first)
        store.accept([
            CloudSyncMutationResult(
                mutationID: mutation.mutationID, status: "accepted", entityID: localID,
                canonicalID: canonicalID, revision: 4, current: JSONValue(data: server)
            )
        ], mutations: [mutation], userID: "u")

        let entities = store.knownEntities(userID: "u", type: .vocabulary)
        #expect(entities[localID] == nil)
        #expect(entities[canonicalID]?.payload == server)
    }

    @Test func rejectedMutationCanBeRetainedWhenLocalEditArrivesInFlight() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteCloudDataSyncStore(baseDirectory: directory)
        let entityID = UUID()
        let payload = Data(#"{"name":"Local","prompt":"draft"}"#.utf8)
        store.stageLocalChanges(userID: "u", type: .persona, entities: [entityID: payload])
        let mutation = try #require(store.pending(userID: "u").first)

        store.accept([
            CloudSyncMutationResult(
                mutationID: mutation.mutationID, status: "conflict", entityID: entityID,
                canonicalID: entityID, revision: 2, current: nil
            )
        ], mutations: [mutation], userID: "u", removeRejected: false)

        #expect(store.pending(userID: "u").map(\.mutationID) == [mutation.mutationID])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
