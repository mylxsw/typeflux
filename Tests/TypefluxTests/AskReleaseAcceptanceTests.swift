import Darwin
import Foundation
@testable import Typeflux
import XCTest

@MainActor
final class AskReleaseAcceptanceTests: XCTestCase {
    func testApprovalJournalAndDiagnosticsStayBoundAfterRollback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let value = AskRecoveryFixture.conversation()
        let run = try XCTUnwrap(value.run), call = try XCTUnwrap(run.pending.first)
        let policy = AskToolPolicy.request(
            call: call, owner: "owner", conversation: value.id, run: run.id, step: String(run.steps),
            binding: .init(target: .init(kind: "browser_tab", id: "tab", version: "doc-1"),
                           toolVersion: "v1", summary: "Fixture"), risk: .read
        )
        let grants = AskApprovalStore()
        let grant = try XCTUnwrap(grants.issue(policy))
        XCTAssertTrue(grants.consume(grant, for: policy))
        XCTAssertFalse(grants.consume(grant, for: policy))
        var audit = AskRecoveryFixture.audit(value)
        audit.approvalId = grant
        audit.argumentsHash = policy.context.argumentsHash
        let cache = try AskConversationCache(url: root.appendingPathComponent("cache.sqlite"))
        let claimed = try await cache.claimExecution(audit, owner: "owner")
        XCTAssertTrue(claimed)
        var context = policy.context
        context.approvalId = grant
        let request = AskToolResultRequest(
            runId: run.id, deviceId: run.deviceId, toolCallId: call.id, content: "private body", isError: true,
            harness: .init(version: 1, context: context, approval: grants.auditScope(grant),
                           outcome: .init(status: "ok", content: [AskTypedContent.json([
                               "type": "text", "text": "private body"
                           ])], durationMs: 9, truncated: true))
        )
        try await cache.saveReceipt(.tool(request), identity: audit.identity, owner: "owner")
        let receiptBytes = try await cache.read(table: "ask_tools", id: audit.identity.key, owner: "owner")
        grants.reset()
        XCTAssertFalse(grants.validateDispatch(grant, for: policy))
        let reopened = try AskConversationCache(url: root.appendingPathComponent("cache.sqlite"))
        let saved = try await reopened.execution(id: audit.identity.key, owner: "owner")
        let entry = try XCTUnwrap(saved)
        XCTAssertEqual(entry.audit?.approvalId, request.harness?.context?.approvalId)
        XCTAssertEqual(entry.audit?.identity.runId, request.runId)
        XCTAssertEqual(entry.audit?.identity.callId, request.toolCallId)
        XCTAssertEqual(entry.audit?.argumentsHash, request.harness?.approval?.argumentsHash)
        let message = request.message(step: run.steps, now: Date())
        XCTAssertTrue(message.diagnostic?.truncated == true)
        XCTAssertEqual(message.diagnostic?.stepId, entry.audit?.identity.stepId)
        try assertRedacted(entry, grant: grant)
        XCTAssertTrue(request.forPeer(nil).isError)
        try await reopened.delete(id: value.id, owner: "owner")
        let retained = try await reopened.execution(id: audit.identity.key, owner: "owner")
        XCTAssertTrue(retained?.deleted == true)
        let retainedBytes = try await reopened.read(table: "ask_tools", id: audit.identity.key, owner: "owner")
        XCTAssertEqual(retainedBytes, receiptBytes)
        XCTAssertFalse(retained?.permits(audit.identity) == true)
    }

    private func assertRedacted(_ entry: AskExecutionEntry, grant: String) throws {
        let diagnostics = try AskCoding.encoder().encode(entry.diagnostic)
        let text = try XCTUnwrap(String(data: diagnostics, encoding: .utf8))
        XCTAssertFalse(text.contains("private"))
        XCTAssertFalse(text.contains(grant))
    }

    func testProjectAndPreviewRollbackPreservesArtifactsAndReapsProcess() async throws {
        let fixture = try AskProjectRuntimeFixture("import time; print('ready', flush=True); time.sleep(30)")
        defer { fixture.close() }
        let store = AskArtifactStore(storageURL: fixture.base.appendingPathComponent("artifacts"))
        let bytes = Data("<h1>Retained release artifact</h1>".utf8)
        let ref = try store.publish(files: ["index.html": bytes], entry: "index.html", scope: fixture.scope)
        let lease = try fixture.launch()
        let started = ContinuousClock.now
        fixture.runtime.shutdown()
        let elapsed = started.duration(to: .now)
        print("R06 isolated project shutdown duration: \(elapsed)")
        let state = try fixture.runtime.status(lease, scope: fixture.scope)
        XCTAssertEqual(kill(state.pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        fixture.runtime = nil
        let disabled = try AskProjectRuntime(
            storageURL: fixture.base.appendingPathComponent("runtime"), projects: fixture.projects
        )
        defer { disabled.shutdown() }
        let launch = AskProjectLaunchRequest(script: "main.py")
        XCTAssertThrowsError(try disabled.start(
            launch, workspace: fixture.workspace, scope: fixture.scope, authorizedRoots: { fixture.roots },
            callId: UUID().uuidString, grantId: "old-grant", approvals: fixture.approvals
        ))
        let bundle = try store.load(ref, scope: fixture.scope)
        let host = AskPreviewHost()
        do {
            _ = try await host.open(.artifact(ref), enabled: false) { _ in bundle }
            XCTFail("Preview rollout is disabled")
        } catch {}
        let reopened = AskArtifactStore(storageURL: store.storageURL)
        let retained = try reopened.load(ref, scope: fixture.scope)
        let exported = fixture.base.appendingPathComponent("retained.html")
        try AskArtifactExport.write(retained, to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("main.py").path))
    }
}
