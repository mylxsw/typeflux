import Foundation
import XCTest
@testable import Typeflux

final class AskRunRouteTests: XCTestCase {
    private func raw(_ text: String) throws -> AskRouteJSON { try AskRouteJSON.decodeRaw(Data(text.utf8)) }
    private func archive(_ text: String) throws -> AskRunRouteArchive { .init(raw: try raw(text)) }
    private func routeRun(_ id: String = "first", device: String = "device", binding: String? = nil) throws -> AskRun {
        var run = AskRun(id: id, deviceId: device, status: "completed", steps: 0, updatedAt: Date(), tools: [], pending: [])
        run.agentBinding = try binding.map { try JSONDecoder().decode(AskAgentBinding.self, from: Data($0.utf8)) }
        return run
    }

    func testExactNumericCodecAndInvalidSyntax() throws {
        let numbers = ["12345678901234567890123456789012345678901234567890",
                       "1.000000000000000000000000000000000000000000000001", "1e200", "1e9999999999999999999999"]
        for token in numbers {
            XCTAssertEqual(try String(decoding: raw(token).encodeRaw(), as: UTF8.self), token)
        }
        for (left, right) in [("1", "1.0"), ("1e0", "0.01e2"), ("-0.00", "0"),
                              ("100e9999999999999999999999", "1e10000000000000000000001"),
                              ("10e-9999999999999999999999", "1e-9999999999999999999998"), ("1.0e-1", "0.1")] {
            XCTAssertEqual(try raw(left), try raw(right))
        }
        XCTAssertNotEqual(try raw(numbers[1]), try raw("1"))
        for invalid in [
            "",
            "01",
            "1.",
            "1e",
            "[1,]",
            "{\"x\":}",
            "true false",
            "[",
            "{",
            "\"unterminated",
            "\"\\uZZZZ\"",
            "{\"x\" 1}",
            "[1 2]"
        ] {
            XCTAssertThrowsError(try raw(invalid), invalid)
        }
        XCTAssertThrowsError(try raw(String(repeating: "[", count: 513) + String(repeating: "]", count: 513)))
        let escaped = #"{"quote":"\"\\\n\u4e2d", "values":[null,true,false,{},[]]}"#
        XCTAssertEqual(try AskRouteJSON.decodeRaw(raw(escaped).encodeRaw()), try raw(escaped))
    }

    func testSameRunExactNumericExtensionConflict() throws {
        let near = "1.000000000000000000000000000000000000000000000001"
        var previous = try routeRun()
        previous
            .agentBinding =
            try AskAgentBinding(raw: raw("{\"id\":\"typeflux.default\",\"version\":1,\"evidence\":\(near)}"))
        let saved = try AskRunRouteArchive.merging(cached: nil, incoming: nil, previous: nil, current: previous)
        var current = previous
        current
            .agentBinding =
            try AskAgentBinding(raw: raw("{\"id\":\"typeflux.default\",\"version\":1.0,\"evidence\":1}"))
        XCTAssertThrowsError(try AskRunRouteArchive.merging(
            cached: saved,
            incoming: nil,
            previous: previous,
            current: current
        ))
        XCTAssertEqual(AskRunRouteArchive.lookup(archive: saved, current: current, runID: "first"), .unavailable)
        current
            .agentBinding =
            try AskAgentBinding(raw: raw("{\"id\":\"typeflux.default\",\"version\":1.0,\"evidence\":\(near)}"))
        XCTAssertEqual(
            try AskRunRouteArchive.merging(cached: saved, incoming: nil, previous: previous, current: current),
            saved
        )
    }

    func testOriginalSnapshotNumericEvidenceSurvivesMetadataSaveAndReload() async throws {
        let huge = "12345678901234567890123456789012345678901234567890"
        let near = "1.000000000000000000000000000000000000000000000001"
        for binding in ["{\"id\":\"typeflux.default\",\"version\":1.0,\"extension_value\":\(huge)}",
                        "{\"id\":\"typeflux.default\",\"version\":\(near),\"extension_value\":\(huge)}",
                        "{\"id\":\"future\",\"version\":9007199254740993.0,\"extension_value\":\(near)}",
                        "[\(huge),\(near)]"] {
            let record = try AskLocalRecord(conversation: AskConversation(id: "numeric", title: "before", revision: 1,
                                                                          updatedAt: Date(), messages: [],
                                                                          run: routeRun()))
            guard case var .object(root) = try raw(String(decoding: AskCoding.encoder().encode(record), as: UTF8.self)),
                  case var .object(conversation) = root["conversation"],
                  case var .object(run) = conversation["run"] else { return XCTFail() }
            let evidence = try raw(binding)
            run["agent_binding"] = evidence
            conversation["run"] = .object(run)
            root["conversation"] = .object(conversation)
            root["agent_routes"] =
                try raw(
                    "{\"version\":1,\"root_extension\":\(near),\"runs\":{\"first\":{\"device_id\":\"device\",\"agent_binding\":\(binding)}}}"
                )
            let store = RouteSnapshotStore()
            // The first load starts from original tokens, before any Foundation decode.
            store.data = try AskRouteJSON.object(root).encodeRaw()
            let engine = AskLocalEngine(directory: URL(fileURLWithPath: "/unused"), snapshotStore: store)
            let loaded = try await engine.conversation(id: "numeric", token: "")
            XCTAssertEqual(loaded.run?.agentBinding?.routeEvidence, evidence)
            if binding.contains("typeflux.default"), !binding.contains(near) {
                XCTAssertNoThrow(try AskAgentBinding.resolve(loaded.run?.agentBinding))
            } else {
                XCTAssertThrowsError(try AskAgentBinding.resolve(loaded.run?.agentBinding))
            }
            _ = try await engine.updateTitle(id: "numeric", request: .init(action: "rename", title: "after"), token: "")
            let savedData = try XCTUnwrap(store.data)
            let saved = try AskLocalRecord.decodeSnapshot(savedData)
            XCTAssertEqual(saved.conversation.title, "after")
            XCTAssertEqual(saved.conversation.run?.agentBinding?.routeEvidence, evidence)
            XCTAssertEqual(saved.agentRoutes?.raw, root["agent_routes"])
            for token in [huge, near] where binding.contains(token) {
                XCTAssertTrue(String(decoding: savedData, as: UTF8.self).contains(token))
            }
            let reopened = AskLocalEngine(directory: URL(fileURLWithPath: "/unused"), snapshotStore: store)
            let reloaded = try await reopened.conversation(id: "numeric", token: "")
            XCTAssertEqual(reloaded.run?.agentBinding?.routeEvidence, evidence)
            let lookup = try await reopened.runRoute(conversationId: "numeric", runId: "first")
            if AskAgentBinding(raw: evidence).isWellFormed {
                guard case .found = lookup else { return XCTFail() }
            } else {
                XCTAssertEqual(lookup, .unavailable)
            }
            var conflict = saved
            conflict.conversation.run?
                .agentBinding = try AskAgentBinding(raw: raw("{\"id\":\"typeflux.default\",\"version\":1}"))
            do { try await reopened.persist(conflict); XCTFail() } catch {}
            XCTAssertEqual(store.data, savedData)
        }
    }

    func testExactOpaqueArchivesAndArchiveCreationFromPreservedBinding() async throws {
        let near = "1.000000000000000000000000000000000000000000000001"
        for opaque in [
            near,
            "12345678901234567890123456789012345678901234567890",
            "[\(near)]",
            "{\"version\":\(near),\"runs\":{}}"
        ] {
            var record = try AskLocalRecord(conversation: AskConversation(id: "opaque", title: "before", revision: 1,
                                                                          updatedAt: Date(), messages: [],
                                                                          run: routeRun()))
            record.agentRoutes = try archive(opaque)
            let store = RouteSnapshotStore()
            store.data = try record.encodeSnapshot()
            let engine = AskLocalEngine(directory: URL(fileURLWithPath: "/unused"), snapshotStore: store)
            _ = try await engine.updateTitle(id: "opaque", request: .init(action: "rename", title: "after"), token: "")
            let reloaded = try AskLocalRecord.decodeSnapshot(XCTUnwrap(store.data))
            XCTAssertEqual(reloaded.agentRoutes?.raw, try raw(opaque))
            let token = opaque.contains(near) ? near : opaque
            XCTAssertTrue(try String(decoding: XCTUnwrap(store.data), as: UTF8.self).contains(token))
        }
        var record = try AskLocalRecord(conversation: AskConversation(
            id: "legacy-numeric",
            title: "before",
            revision: 1,
            updatedAt: Date(),
            messages: [],
            run: routeRun()
        ))
        let evidence = try raw("{\"id\":\"typeflux.default\",\"version\":\(near)}")
        record.conversation.run?.agentBinding = AskAgentBinding(raw: evidence)
        let store = RouteSnapshotStore()
        store.data = try record.encodeSnapshot()
        let engine = AskLocalEngine(directory: URL(fileURLWithPath: "/unused"), snapshotStore: store)
        _ = try await engine.updateTitle(
            id: "legacy-numeric",
            request: .init(action: "rename", title: "after"),
            token: ""
        )
        let saved = try AskLocalRecord.decodeSnapshot(XCTUnwrap(store.data))
        XCTAssertEqual(
            saved.agentRoutes,
            try AskRunRouteArchive.merging(cached: nil, incoming: nil, previous: nil, current: record.conversation.run)
        )
        let exact = try AskAgentBinding(raw: raw("{\"id\":\"typeflux.default\",\"version\":1}"))
        record.conversation.run?.agentBinding = exact
        do { try await engine.persist(record); XCTFail() } catch {}
    }

    func testDecisionTableAndLosslessValues() throws {
        for value in ["null", "true", "42", "1e200", "\"opaque\"", "[null,false,3.25,\"s\",{}]", "{\"version\":2,\"runs\":{}}", "{\"version\":1,\"runs\":{\"first\":{}}}"] {
            let value = try archive(value)
            XCTAssertEqual(try JSONDecoder().decode(AskRunRouteArchive.self, from: JSONEncoder().encode(value)), value)
            XCTAssertEqual(AskRunRouteArchive.lookup(archive: value, current: try routeRun(), runID: "first"), .unavailable)
            XCTAssertEqual(try AskRunRouteArchive.merging(cached: value, incoming: value, previous: routeRun(), current: routeRun()), value)
            XCTAssertThrowsError(try AskRunRouteArchive.merging(cached: value, incoming: value, previous: routeRun(), current: routeRun("new")))
        }
        XCTAssertNil(try AskRunRouteArchive.merging(cached: nil, incoming: nil, previous: nil, current: nil))
        XCTAssertEqual(AskRunRouteArchive.lookup(archive: nil, current: nil, runID: "old"), .unrecorded)
        XCTAssertEqual(AskRunRouteArchive.lookup(archive: nil, current: try routeRun(), runID: "old"), .unrecorded)
        XCTAssertEqual(AskRunRouteArchive.lookup(archive: nil, current: try routeRun(), runID: ""), .unavailable)
        XCTAssertThrowsError(try AskRunRouteArchive.merging(cached: nil, incoming: nil, previous: nil, current: routeRun("")))
        for binding in [nil, "null", "{\"version\":1,\"id\":\"typeflux.default\"}", "{\"id\":\"future\",\"version\":2,\"extra\":[1]}", "false", "{\"version\":\"bad\"}"] as [String?] {
            let current = try routeRun(binding: binding)
            let saved = try XCTUnwrap(AskRunRouteArchive.merging(cached: nil, incoming: nil, previous: nil, current: current))
            let expected = binding == "false" || binding == "{\"version\":\"bad\"}" ? AskRunRouteLookup.unavailable : .found(.init(runID: "first", deviceID: "device", binding: .effectiveBinding(try binding.map(raw))), source: .archived)
            XCTAssertEqual(AskRunRouteArchive.lookup(archive: saved, current: current, runID: "first"), expected)
            if case let .found(route, _) = expected {
                XCTAssertEqual(AskRunRouteArchive.lookup(archive: nil, current: current, runID: "first"), .found(route, source: .currentSnapshot))
            }
            XCTAssertEqual(try AskRunRouteArchive.merging(cached: saved, incoming: saved, previous: current, current: current), saved)
            XCTAssertThrowsError(try AskRunRouteArchive.merging(cached: saved, incoming: saved, previous: current, current: routeRun(device: "other", binding: binding)))
            XCTAssertEqual(AskRunRouteArchive.lookup(archive: saved, current: try routeRun(device: "other", binding: binding), runID: "old"), .unavailable)
        }
        let legacy = try archive("{\"version\":1,\"runs\":{\"first\":{\"device_id\":\"device\"}}}")
        XCTAssertNoThrow(try AskRunRouteArchive.merging(cached: legacy, incoming: nil, previous: nil, current: routeRun(binding: "{\"id\":\"typeflux.default\",\"version\":1}")))
        let reordered = try routeRun(binding: "{\"version\":1.0,\"id\":\"typeflux.default\"}")
        XCTAssertEqual(AskRunRouteArchive.lookup(archive: legacy, current: reordered, runID: "first"), .found(.init(runID: "first", deviceID: "device", binding: .defaultBinding), source: .archived))
    }

    func testOpaqueCachedArchiveWinsStaleMetadataCopies() throws {
        let opaque = try archive("false")
        let current = try routeRun()
        let known = try AskRunRouteArchive.merging(cached: nil, incoming: nil, previous: nil, current: current)
        XCTAssertEqual(try AskRunRouteArchive.merging(cached: opaque, incoming: known, previous: current, current: current), opaque)
        XCTAssertThrowsError(try AskRunRouteArchive.merging(cached: opaque, incoming: known, previous: current, current: routeRun("replacement")))
        let conflicting = try AskRunRouteArchive.merging(cached: nil, incoming: nil, previous: nil, current: routeRun(device: "conflict"))
        XCTAssertThrowsError(try AskRunRouteArchive.merging(cached: opaque, incoming: conflicting, previous: current, current: current))
        XCTAssertThrowsError(try AskRunRouteArchive.merging(cached: known, incoming: opaque, previous: current, current: current))
        XCTAssertEqual(try AskRunRouteArchive.merging(cached: nil, incoming: opaque, previous: nil, current: nil), opaque)
    }

    func testBindingExtensionsPreserveGuardAndStructuralIdentity() throws {
        let text = "{\"id\":\"typeflux.default\",\"version\":1,\"extra\":[1]}"
        let binding = try JSONDecoder().decode(AskAgentBinding.self, from: Data(text.utf8))
        XCTAssertEqual(try AskAgentBinding.resolve(binding), .default)
        XCTAssertEqual(try JSONDecoder().decode(AskRouteJSON.self, from: JSONEncoder().encode(binding)), try raw(text))
        let current = try routeRun(binding: text)
        let archive = try AskRunRouteArchive.merging(cached: nil, incoming: nil, previous: nil, current: current)
        XCTAssertThrowsError(try AskRunRouteArchive.merging(cached: archive, incoming: nil, previous: current, current: routeRun()))
    }

    func testStaleCopiesUnionAndConflicts() throws {
        let a = try AskRunRouteArchive.merging(cached: nil, incoming: nil, previous: nil, current: routeRun())
        let b = try AskRunRouteArchive.merging(cached: a, incoming: a, previous: routeRun(), current: routeRun("second"))
        let c = try AskRunRouteArchive.merging(cached: b, incoming: a, previous: routeRun("second"), current: routeRun("third"))
        for id in ["first", "second", "third"] {
            guard case .found = AskRunRouteArchive.lookup(archive: c, current: try routeRun("third"), runID: id) else { return XCTFail(id) }
        }
        let conflict = try AskRunRouteArchive.merging(cached: nil, incoming: nil, previous: nil, current: routeRun(device: "different"))
        XCTAssertThrowsError(try AskRunRouteArchive.merging(cached: b, incoming: conflict, previous: routeRun("second"), current: routeRun("third")))
        XCTAssertEqual(AskRunRouteArchive.lookup(archive: b, current: try routeRun("second"), runID: "third"), .unrecorded)
    }

    func testAtomicPersistenceStaleCopiesAndReadOnlyLookup() async throws {
        let store = RouteSnapshotStore()
        let engine = AskLocalEngine(directory: URL(fileURLWithPath: "/unused"), snapshotStore: store)
        var original = AskLocalRecord(conversation: AskConversation(id: "conversation", title: "title", revision: 1, updatedAt: Date(), messages: [], run: try routeRun()))
        original.conversation.memory = AskMemory(global: "memory")
        try await engine.persist(original)
        let first = store.data
        let lookup = try await engine.runRoute(conversationId: "conversation", runId: "first")
        guard case .found(_, source: .archived) = lookup else { return XCTFail() }
        XCTAssertEqual(store.data, first)
        var stale = original
        stale.conversation.run = try routeRun("second")
        try await engine.persist(stale)
        stale.conversation.run = try routeRun("third")
        try await engine.persist(stale)
        for id in ["first", "second", "third"] {
            let found = try await engine.runRoute(conversationId: "conversation", runId: id)
            guard case .found = found else { return XCTFail(id) }
        }
        try await engine.purgeMemory(token: "")
        let purged = try AskCoding.decoder().decode(AskLocalRecord.self, from: XCTUnwrap(store.data))
        XCTAssertNil(purged.conversation.memory)
        let before = store.data
        stale.conversation.run = try routeRun(device: "collision")
        do { try await engine.persist(stale); XCTFail() } catch {}
        XCTAssertEqual(before, store.data)
        stale.conversation.run = try routeRun("fourth")
        store.fail = true
        do { try await engine.persist(stale); XCTFail() } catch {}
        XCTAssertEqual(before, store.data)
        let missing = try await engine.runRoute(conversationId: "conversation", runId: "fourth")
        XCTAssertEqual(missing, .unrecorded)
        store.fail = false
        let reopened = AskLocalEngine(directory: URL(fileURLWithPath: "/unused"), snapshotStore: store)
        let reopenedLookup = try await reopened.runRoute(conversationId: "conversation", runId: "first")
        XCTAssertEqual(reopenedLookup, lookup)
        do { _ = try await reopened.runRoute(conversationId: "missing", runId: "first"); XCTFail() } catch {}
        do { _ = try await reopened.runRoute(conversationId: "conversation", runId: "../bad"); XCTFail() } catch {}
        try await reopened.delete(conversationId: "conversation", token: "")
        XCTAssertNil(store.data)
    }

    func testMalformedRecordMetadataAndLegacyReadDoNotBackfill() async throws {
        for archive in [nil, "null", "false", "1e200", "[1]", "{\"version\":99}"] as [String?] {
            let store = RouteSnapshotStore()
            var record = AskLocalRecord(conversation: AskConversation(id: "legacy", title: "title", revision: 1, updatedAt: Date(), messages: [], run: try routeRun()))
            record.agentRoutes = try archive.map(self.archive)
            store.data = try AskCoding.encoder().encode(record)
            let engine = AskLocalEngine(directory: URL(fileURLWithPath: "/unused"), snapshotStore: store)
            let before = store.data
            let result = try await engine.runRoute(conversationId: "legacy", runId: "first")
            XCTAssertEqual(result, archive == nil ? .found(.init(runID: "first", deviceID: "device", binding: .defaultBinding), source: .currentSnapshot) : .unavailable)
            XCTAssertEqual(before, store.data)
            _ = try await engine.conversation(id: "legacy", token: "")
            record.conversation.title = "metadata"
            try await engine.persist(record)
            let saved = try AskCoding.decoder().decode(AskLocalRecord.self, from: XCTUnwrap(store.data))
            XCTAssertEqual(saved.conversation.title, "metadata")
            if archive != nil { XCTAssertEqual(saved.agentRoutes, record.agentRoutes) }
        }
    }

    func testLookupSkipsHousekeepingAndFailedKeepRetainsTemporaryState() async throws {
        let store = RouteSnapshotStore()
        var record = AskLocalRecord(conversation: AskConversation(id: "expired", title: "title", revision: 1, updatedAt: .distantPast, messages: [], run: try routeRun()))
        record.conversation.run?.status = "running"
        record.conversation.run?.updatedAt = .distantPast
        record.conversation.memory = AskMemory(global: "expired", expiry: .distantPast)
        store.data = try AskCoding.encoder().encode(record)
        let before = store.data
        let engine = AskLocalEngine(directory: URL(fileURLWithPath: "/unused"), snapshotStore: store)
        _ = try await engine.runRoute(conversationId: "expired", runId: "first")
        XCTAssertEqual(store.data, before)
        var request = AskSendRequest(id: UUID().uuidString, deviceId: "device", text: "question", tools: [], modelRef: "custom:model")
        request.temporary = true
        let c = try await engine.send(conversationId: "temp", request: request, token: "")
        store.fail = true
        do { _ = try await engine.keep(conversationId: c.id, token: ""); XCTFail() } catch {}
        let temporary = await engine.isTemporary(c.id)
        XCTAssertTrue(temporary)
        XCTAssertEqual(store.data, before)
        store.fail = false
        _ = try await engine.keep(conversationId: c.id, token: "")
        guard case .found(_, source: .archived) = try await engine.runRoute(conversationId: c.id, runId: c.run!.id) else { return XCTFail() }
    }

    func testReplacementTemporaryKeepAndPurge() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = AskLocalEngine(directory: directory)
        var request = AskSendRequest(id: UUID().uuidString, deviceId: "device", text: "question", tools: [], modelRef: "custom:model")
        request.temporary = true
        var c = try await engine.send(conversationId: "temporary", request: request, token: "")
        var ids = [c.run!.id]
        c = try await engine.inferenceResult(conversationId: c.id, request: .init(runId: c.run!.id, deviceId: "device", inferenceId: c.run!.inference!.id, content: "answer"), token: "")
        c = try await engine.regenerate(conversationId: c.id, request: .init(messageId: c.messages.last!.id, deviceId: "device", modelRef: nil), token: "")
        ids.append(c.run!.id)
        c = try await engine.cancel(conversationId: c.id, runId: c.run!.id, token: "")
        c = try await engine.retry(conversationId: c.id, runId: c.run!.id, deviceId: "device", modelRef: nil, token: "")
        ids.append(c.run!.id)
        c = try await engine.cancel(conversationId: c.id, runId: c.run!.id, token: "")
        request.id = UUID().uuidString
        c = try await engine.send(conversationId: c.id, request: request, token: "")
        ids.append(c.run!.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        _ = try await engine.keep(conversationId: c.id, token: "")
        try await engine.purgeMemory(token: "")
        let reopened = AskLocalEngine(directory: directory)
        for id in ids {
            guard case .found(_, source: .archived) = try await reopened.runRoute(conversationId: c.id, runId: id) else { return XCTFail(id) }
        }
        let publicData = try AskCoding.encoder().encode(c)
        XCTAssertFalse(String(decoding: publicData, as: UTF8.self).contains("agent_routes"))
    }
}

private final class RouteSnapshotStore: AskLocalSnapshotStoring, @unchecked Sendable {
    // Tests access this store only between awaited actor calls.
    var data: Data?
    var fail = false
    func forEachSnapshot(_ consume: (Data) -> Void) { if let data { consume(data) } }
    func writeSnapshot(_ data: Data, id _: String) throws {
        if fail { throw CocoaError(.fileWriteUnknown) }
        self.data = data
    }
    func removeSnapshot(id _: String) throws { data = nil }
}
