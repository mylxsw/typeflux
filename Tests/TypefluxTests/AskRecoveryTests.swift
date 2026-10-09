import Foundation
import SQLite3
import Testing
@testable import Typeflux

enum AskRecoveryFixture {
    static func conversation(model: Bool = false) -> AskConversation {
        let call = AskToolCall(
            id: "call",
            function: .init(name: "browser", arguments: #"{"action":"read","secret":"private"}"#)
        )
        return .init(
            id: "conversation",
            title: "Recovery",
            revision: 2,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            messages: [.init(id: "question", role: "user", text: "Inspect the page", createdAt: Date())],
            run: .init(
                id: "run",
                deviceId: "device",
                status: model ? "waiting_inference" : "waiting_tool",
                steps: 1,
                updatedAt: Date(),
                tools: [],
                pending: model ? [] : [call],
                modelRef: "custom:unavailable",
                inference: model ? .init(id: "call", payload: "private prompt", summaryThrough: nil) :
                    nil
            )
        )
    }

    static func audit(_ value: AskConversation, owner: String = "owner", model: Bool = false) -> AskExecutionAudit {
        .init(
            identity: .init(
                owner: owner,
                conversation: value,
                run: value.run!,
                callId: "call",
                kind: model ? "model" : "tool"
            ),
            toolVersion: "v1",
            argumentsHash: AskToolPolicy.digest("private input"),
            approvalId: model ? nil : "approval"
        )
    }

    static func receipt(_ value: AskConversation, model: Bool = false) -> AskExecutionReceipt {
        model ? .inference(.init(
            runId: value.run!.id,
            deviceId: "device",
            inferenceId: "call",
            content: "Saved answer"
        ))
            : .tool(.init(
                runId: value.run!.id,
                deviceId: "device",
                toolCallId: "call",
                content: "Saved result",
                isError: false
            ))
    }
}

@Suite("Ask recovery journal")
struct AskRecoveryJournalTests {
    @Test(arguments: [false, true]) func `crash boundaries and receipt immutability`(model: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache.sqlite")
        let cache = try AskConversationCache(url: url)
        let value = AskRecoveryFixture.conversation(model: model)
        let audit = AskRecoveryFixture.audit(value, model: model), receipt = AskRecoveryFixture.receipt(
            value,
            model: model
        )
        #expect(try await cache.execution(id: audit.identity.key, owner: "owner") == nil)
        #expect(try await cache.claimExecution(audit, owner: "owner"))
        let restarted = try AskConversationCache(url: url)
        #expect(try await !restarted.claimExecution(audit, owner: "owner"))
        let unknown = try #require(await restarted.execution(id: audit.identity.key, owner: "owner"))
        #expect(unknown.unknown && !unknown.acknowledged)
        #expect(!unknown.permits(audit.identity))
        try await restarted.saveReceipt(receipt, identity: audit.identity, owner: "owner")
        try await restarted.saveReceipt(receipt, identity: audit.identity, owner: "owner")
        let again = try AskConversationCache(url: url)
        var entry = try #require(await again.execution(id: audit.identity.key, owner: "owner"))
        #expect(entry.receipt == receipt && entry.permits(audit.identity))
        #expect(!entry.unknown && !entry.acknowledged)
        #expect(try await again.executions(conversationId: value.id, owner: "other").isEmpty)
        for event in [AskExecutionAudit.Event.retransmitting, .acknowledged, .ended] {
            try await again.recordExecution(id: entry.id, event: event, owner: "owner")
        }
        entry = try #require(await again.execution(id: entry.id, owner: "owner"))
        #expect(entry.acknowledged)
        #expect(entry.audit?.events == [.claimed, .receiptSaved, .retransmitting, .acknowledged, .ended])
        var wrong = audit.identity; wrong.deviceId = "new-device"
        #expect(!entry.permits(wrong))
        await #expect(throws: AskRecoveryError.self) { try await again.saveReceipt(
            receipt,
            identity: wrong,
            owner: "owner"
        ) }
        let different: AskExecutionReceipt = model
            ? .inference(.init(runId: "run", deviceId: "device", inferenceId: "call", content: "Changed"))
            : .tool(.init(runId: "run", deviceId: "device", toolCallId: "call", content: "Changed", isError: false))
        await #expect(throws: AskRecoveryError.self) { try await again.saveReceipt(
            different,
            identity: audit.identity,
            owner: "owner"
        ) }
        try await again.delete(id: value.id, owner: "owner")
        entry = try #require(await again.execution(id: entry.id, owner: "owner"))
        #expect(entry.deleted && entry.receipt == receipt && !entry.permits(audit.identity))
        await #expect(throws: AskRecoveryError.self) { try await again.claimExecution(audit, owner: "owner") }
        #expect(try await again.load(id: value.id, owner: "owner") == nil)
    }

    @Test func `claim and receipt failures are atomic across connections`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache.sqlite")
        let cache = try AskConversationCache(url: url)
        var sqliteDB: OpaquePointer?
        #expect(sqlite3_open(url.path, &sqliteDB) == SQLITE_OK)
        defer { sqlite3_close(sqliteDB) }
        let audit = AskRecoveryFixture.audit(AskRecoveryFixture.conversation())
        #expect(sqlite3_exec(
            sqliteDB,
            "CREATE TRIGGER fail_claim BEFORE INSERT ON ask_execution BEGIN SELECT RAISE(ABORT,'fixture'); END;",
            nil,
            nil,
            nil
        ) == SQLITE_OK)
        await #expect(throws: (any Error).self) { try await cache.claimExecution(audit, owner: "owner") }
        #expect(try await cache.execution(id: audit.identity.key, owner: "owner") == nil)
        #expect(try await cache.executions(conversationId: "conversation", owner: "owner").isEmpty)
        #expect(sqlite3_exec(sqliteDB, "DROP TRIGGER fail_claim;", nil, nil, nil) == SQLITE_OK)
        let other = try AskConversationCache(url: url)
        async let first = cache.claimExecution(audit, owner: "owner")
        async let second = other.claimExecution(audit, owner: "owner")
        let claims = try await [first, second]
        #expect(claims.filter(\.self).count == 1)
        #expect(sqlite3_exec(
            sqliteDB,
            "CREATE TRIGGER fail_receipt BEFORE UPDATE ON ask_execution BEGIN SELECT RAISE(ABORT,'fixture'); END;",
            nil,
            nil,
            nil
        ) == SQLITE_OK)
        await #expect(throws: (any Error).self) {
            try await cache.saveReceipt(
                AskRecoveryFixture.receipt(AskRecoveryFixture.conversation()),
                identity: audit.identity,
                owner: "owner"
            )
        }
        #expect(try await other.execution(id: audit.identity.key, owner: "owner")?.receipt == nil)
        #expect(sqlite3_exec(sqliteDB, "DROP TRIGGER fail_receipt;", nil, nil, nil) == SQLITE_OK)
        await #expect(throws: AskRecoveryError.self) { try await cache.recordExecution(
            id: "absent",
            event: .ended,
            owner: "owner"
        ) }
        var invalid = audit; invalid.identity.deviceId = ""
        await #expect(throws: AskRecoveryError.self) { try await cache.claimExecution(invalid, owner: "owner") }
    }

    @Test func `legacy database migrates without inventing identity or destroying history`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("legacy.sqlite")
        var sqliteDB: OpaquePointer?
        #expect(sqlite3_open(url.path, &sqliteDB) == SQLITE_OK)
        #expect(sqlite3_exec(
            sqliteDB,
            "CREATE TABLE ask_tools(owner TEXT NOT NULL,id TEXT NOT NULL,data BLOB,PRIMARY KEY(owner,id)); "
                + "INSERT INTO ask_tools(owner,id) VALUES('owner','run/call');",
            nil,
            nil,
            nil
        ) == SQLITE_OK)
        sqlite3_close(sqliteDB)
        let cache = try AskConversationCache(url: url)
        let value = AskRecoveryFixture.conversation()
        try await cache.save(value, owner: "owner")
        try await cache.associateTool(id: "run/call", conversationId: value.id, owner: "owner")
        let entries = try await cache.executions(conversationId: value.id, owner: "owner")
        #expect(entries.count == 1 && entries[0].audit == nil && entries[0].unknown)
        #expect(try await !cache.claimExecution(AskRecoveryFixture.audit(value), owner: "owner"))
        #expect(try await cache.load(id: value.id, owner: "owner")?.run?.id == value.run?.id)
        #expect(try await cache.list(owner: "owner").count == 1)
        try await cache.delete(id: value.id, owner: "owner")
        #expect(try await cache.execution(id: "run/call", owner: "owner") != nil)
        // A pre-R04 binary still issues these deletes during conversation removal.
        #expect(sqlite3_open(url.path, &sqliteDB) == SQLITE_OK)
        #expect(sqlite3_exec(sqliteDB, "DELETE FROM ask_tools; DELETE FROM ask_tool_owners;", nil, nil, nil) ==
            SQLITE_OK)
        sqlite3_close(sqliteDB)
        #expect(try await cache.execution(id: "run/call", owner: "owner") != nil)
        #expect(try await cache.executions(conversationId: value.id, owner: "owner").count == 1)
    }

    @Test func `diagnostics are bounded and do not contain private input`() throws {
        var audit = AskRecoveryFixture.audit(AskRecoveryFixture.conversation())
        audit.identity.runId = String(repeating: "secret-token", count: 1000)
        audit.identity.callId = "https://private.example/secret"
        for _ in 0 ..< 50 {
            audit.record(.retransmitting); audit.record(.ended)
        }
        #expect(audit.events.count == 32)
        audit.record(.ended)
        #expect(audit.events.count == 32)
        let entry = AskExecutionEntry(id: "irrelevant", audit: audit)
        let bytes = try AskCoding.encoder().encode(#require(entry.diagnostic))
        let diagnostic = try #require(String(data: bytes, encoding: .utf8))
        #expect(!diagnostic.contains("secret") && !diagnostic.contains("private") && bytes.count < 350)
        #expect(AskExecutionEntry(id: "legacy").diagnostic == nil)
        #expect(AskRecoveryError.binding.errorDescription != nil && AskRecoveryError.storage.errorDescription != nil)
    }
}

@Suite("Ask recovery interactions", .serialized, .exclusiveUIState)
@MainActor
struct AskRecoveryInteractionTests {
    @Test func `unreadable journal cannot enable resume`() async throws {
        let fixture = try AskTestFixture(), value = AskRecoveryFixture.conversation()
        await fixture.api.seed(value)
        var sqliteDB: OpaquePointer?
        #expect(sqlite3_open(fixture.root.appendingPathComponent("cache.sqlite").path, &sqliteDB) == SQLITE_OK)
        #expect(sqlite3_exec(sqliteDB, "DROP TABLE ask_tool_owners", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(sqliteDB)
        await fixture.model.select(value.id)
        fixture.model.resume()
        #expect(fixture.model.recoveryBlocksResume(value) && fixture.model.inspectingRecovery)
        #expect(fixture.tools.executions == 0)
        fixture.model.resetSession()
    }

    @Test func `local account switch hides previous account receipt and failed cancel never confirms end`(
    ) async throws {
        let fixture = try AskTestFixture(localOnly: true), value = AskRecoveryFixture.conversation()
        let audit = AskRecoveryFixture.audit(value, owner: "previous-account")
        _ = try await fixture.cache.claimExecution(audit, owner: AskRoutedAPI.localOwner)
        try await fixture.cache.saveReceipt(
            AskRecoveryFixture.receipt(value),
            identity: audit.identity,
            owner: AskRoutedAPI.localOwner
        )
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        #expect(fixture.model.selectedRecoveryEntries.first?.receipt == nil)
        #expect(fixture.model.selectedRecoveryEntries.first?.audit == nil)
        await fixture.model.retransmitSavedReceipts()
        #expect(await fixture.api.results.isEmpty)
        await fixture.api.failGet(value.id)
        await fixture.model.endRecoveryRun()
        #expect(fixture.model.selected?.run?.isActive == true)
        #expect(fixture.model.error != nil)
        fixture.model.dismissRecoveryInspector()
        #expect(fixture.model.commandFeedback == nil)
        fixture.model.resetSession()
    }

    private func model(_ fixture: AskTestFixture, device: String = "device") throws -> AskConversationModel {
        let cache = try AskConversationCache(url: fixture.root.appendingPathComponent("cache.sqlite"))
        return AskConversationModel(
            api: fixture.api,
            cache: cache,
            tools: fixture.tools,
            capture: fixture.capture,
            deviceId: device,
            modelLibrary: fixture.model.modelLibrary,
            session: { (fixture.sessionState.owner, "token") }
        )
    }

    @Test(arguments: [
        false,
        true
    ]) func `restart only resends saved receipt even without model or approval`(model inference: Bool) async throws {
        let fixture = try AskTestFixture(), value = AskRecoveryFixture.conversation(model: inference)
        let audit = AskRecoveryFixture.audit(value, model: inference), receipt = AskRecoveryFixture.receipt(
            value,
            model: inference
        )
        await fixture.api.seed(value)
        #expect(try await fixture.cache.claimExecution(audit, owner: "owner"))
        try await fixture.cache.saveReceipt(receipt, identity: audit.identity, owner: "owner")
        let restarted = try model(fixture)
        await restarted.select(value.id)
        #expect(restarted.hasRecoveryNotice && restarted.canRetransmitReceipts)
        #expect(fixture.tools.executions == 0 && restarted.pendingApprovals.isEmpty)
        #expect(await fixture.api.results.isEmpty)
        #expect(await fixture.api.inferenceResults.isEmpty)
        await restarted.retransmitSavedReceipts()
        #expect(fixture.tools.executions == 0)
        #expect(await fixture.api.results.count == (inference ? 0 : 1))
        #expect(await fixture.api.inferenceResults.count == (inference ? 1 : 0))
        #expect(restarted.selected?.run?.status == "completed")
        #expect(!restarted.canRetransmitReceipts)
        #expect(!restarted.hasRecoveryNotice)
        await restarted.retransmitSavedReceipts()
        let resultCount = await fixture.api.results.count
        #expect(await fixture.api.inferenceResults.count + resultCount == 1)
        restarted.resetSession()
    }

    @Test(arguments: [
        false,
        true
    ]) func `unknown claim can be inspected and ended but never replayed`(model inference: Bool) async throws {
        let fixture = try AskTestFixture(), value = AskRecoveryFixture.conversation(model: inference)
        let audit = AskRecoveryFixture.audit(value, model: inference)
        await fixture.api.seed(value)
        _ = try await fixture.cache.claimExecution(audit, owner: "owner")
        await fixture.model.select(value.id)
        fixture.model.resume()
        #expect(fixture.model.inspectingRecovery && fixture.model.recoveryBlocksResume(value))
        #expect(fixture.model.hasRecoveryNotice && !fixture.model.recoveryPresentation.canContinue)
        await fixture.model.retransmitSavedReceipts()
        #expect(await fixture.api.results.isEmpty)
        #expect(await fixture.api.inferenceResults.isEmpty)
        #expect(fixture.tools.executions == 0 && fixture.model.pendingApprovals.isEmpty)
        fixture.model.draft.text = "Previously queued instruction"
        fixture.model.submitDraft()
        #expect(fixture.model.queuedMessages.count == 1)
        #expect(!fixture.model.canSteer)
        await fixture.model.endRecoveryRun()
        fixture.model.resumeQueue()
        #expect(fixture.model.isQueuePaused)
        #expect(fixture.model.selected?.run?.status == "cancelled")
        #expect(fixture.model.selectedRecoveryEntries.first?.unknown == true)
        fixture.model.resume()
        fixture.model.regenerate("previous-answer")
        #expect(await fixture.api.regenerations.isEmpty)
        #expect(await fixture.api.retryModels.isEmpty)
        fixture.model.dismissRecoveryInspector()
        #expect(!fixture.model.inspectingRecovery && fixture.model.commandFeedback == nil)
        #expect(await fixture.api.sends.isEmpty)
        #expect(try await fixture.cache.execution(id: audit.identity.key, owner: "owner")?.receipt == nil)
        fixture.model.resetSession()
    }

    @Test func `completed tool with failed delivery survives model and cache restart`() async throws {
        let fixture = try AskTestFixture()
        await fixture.api.setTool(.init(id: "call", function: .init(name: "browser", arguments: #"{"action":"read"}"#)))
        await fixture.api.setFailReceipts(true)
        fixture.model.launcherDraft.text = "Read this page"; fixture.model.setPermissionMode(.strict, launcher: true)
        fixture.model.submitLauncher()
        try await fixture.wait { !fixture.model.pendingApprovals.isEmpty }
        let id = try #require(fixture.model.selectedId)
        fixture.model.approve(conversationId: id, allowed: true)
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.tools.executions == 1)
        #expect(await fixture.api.results.isEmpty)
        let entries = try await fixture.cache.executions(conversationId: id, owner: "owner")
        #expect(entries.first?.receipt?.status == "ok")
        #expect(entries.first?.audit?.approvalId != nil)
        fixture.model.resetSession()
        let restarted = try model(fixture)
        await restarted.select(id)
        #expect(restarted.hasRecoveryNotice && restarted.canRetransmitReceipts)
        await restarted.retransmitSavedReceipts()
        #expect(restarted.hasRecoveryNotice && restarted.canRetransmitReceipts && fixture.tools.executions == 1)
        await fixture.api.setFailReceipts(false)
        await restarted.retransmitSavedReceipts()
        #expect(fixture.tools.executions == 1 && restarted.selected?.run?.status == "completed")
        #expect(!restarted.hasRecoveryNotice && !restarted.canRetransmitReceipts)
        #expect(await fixture.api.results.count == 1)
        restarted.resetSession()
    }

    @Test func `wrong account and device cannot send saved bytes`() async throws {
        let fixture = try AskTestFixture(), value = AskRecoveryFixture.conversation()
        let audit = AskRecoveryFixture.audit(value)
        _ = try await fixture.cache.claimExecution(audit, owner: "owner")
        try await fixture.cache.saveReceipt(AskRecoveryFixture.receipt(value), identity: audit.identity, owner: "owner")
        await fixture.api.seed(value)
        let replacement = try model(fixture, device: "replacement")
        await replacement.select(value.id)
        #expect(!replacement.canRetransmitReceipts)
        await replacement.retransmitSavedReceipts()
        #expect(await fixture.api.results.isEmpty)
        replacement.resetSession()
        await fixture.model.select(value.id)
        await fixture.api.hold(value.id)
        let delivery = Task { await fixture.model.retransmitSavedReceipts() }
        await Task.yield()
        fixture.sessionState.owner = "other"
        fixture.model.resetSession()
        await fixture.api.release(value.id)
        await delivery.value
        #expect(await fixture.api.results.isEmpty)
        #expect(fixture.model.selected == nil && fixture.model.recoveryEntries.isEmpty)
    }

    @Test func `future protocol and remote unknown remain inspectable without fabricated evidence`() async throws {
        let fixture = try AskTestFixture()
        for recovery in [
            AskRunRecovery(state: "unknown_outcome", sequence: 7),
            .init(version: 2, state: "waiting_device", sequence: 8)
        ] {
            var value = AskRecoveryFixture.conversation()
            value.run?.recovery = recovery
            await fixture.api.seed(value)
            await fixture.model.select(value.id, reload: true)
            fixture.model.resume()
            #expect(fixture.model.inspectingRecovery && fixture.model.selectedRecoveryEntries.isEmpty)
            #expect(fixture.model.hasRecoveryNotice && !fixture.model.recoveryPresentation.canContinue)
            #expect(fixture.tools.executions == 0 && fixture.model.busyIds.isEmpty)
        }
        fixture.model.resetSession()
    }
}
