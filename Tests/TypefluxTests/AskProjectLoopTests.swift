import AppKit
import Darwin
import SwiftUI
@testable import Typeflux
import WebKit
import XCTest

@MainActor final class AskProjectLoopTests: XCTestCase {
    @MainActor final class Fixture {
        let runtime: AskProjectRuntimeFixture
        let tools: AskLocalTools
        let store: AskArtifactStore
        let settings: SettingsStore
        let approvals = AskApprovalStore()

        init(kind: String = "frontend") throws {
            runtime = try AskProjectRuntimeFixture()
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("docs/harness/d04-fixtures/" + kind)
            for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try FileManager.default.copyItem(
                    at: file,
                    to: runtime.source.appendingPathComponent(file.lastPathComponent)
                )
            }
            settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
            settings.askFileAccessFolders = runtime.roots
            store = AskArtifactStore(storageURL: runtime.base.appendingPathComponent("artifacts"))
            tools = AskLocalTools(registry: MCPRegistry(settingsStore: .init(defaults: settings.defaults)),
                                  settings: settings, projects: runtime.projects, projectModeEnabled: true,
                                  artifactStore: store, artifactCreationEnabled: true, artifactPreviewEnabled: true,
                                  projectRuntime: runtime.runtime)
            tools.bindExecution(
                ownerId: runtime.scope.ownerId,
                conversationId: runtime.scope.conversationId,
                runId: runtime.scope.runId
            )
        }

        func close() {
            runtime.close()
        }

        func call(_ name: String, _ args: [String: Any]) throws -> AskToolCall {
            try .init(id: UUID().uuidString, function: .init(name: name, arguments: String(decoding:
                JSONSerialization.data(withJSONObject: args, options: .sortedKeys), as: UTF8.self)))
        }

        func invoke(_ name: String, _ args: [String: Any]) async throws -> AskLocalToolOutput {
            let call = try call(name, args), scope = runtime.scope
            let binding = try await tools.approvalBinding(for: call, conversationId: scope.conversationId)
            let request = AskToolPolicy.request(call: call, owner: scope.ownerId, conversation: scope.conversationId,
                                                run: scope.runId, step: call.id, binding: binding,
                                                risk: tools.risk(of: call))
            let id = try XCTUnwrap(approvals.issue(request))
            XCTAssertTrue(approvals.consume(id, for: request)); XCTAssertFalse(approvals.consume(id, for: request))
            return try await tools.executeApproved(call, conversationId: scope.conversationId, binding: binding) {
                guard self.approvals.validateDispatch(id, for: request)
                else { throw AskProjectRuntimeError.approvalRequired }
            }
        }

        func edit() async throws -> AskProjectReview {
            let id = runtime.workspace.id
            let read = try await invoke("project_files", ["action": "read", "workspace_id": id, "path": "index.html"])
            let page = try JSONDecoder().decode(AskProjectRead.self, from: Data(read.content.utf8))
            let edited = try await invoke("project_files", ["action": "edit", "workspace_id": id, "path": "index.html",
                                                            "expected_version": page.version, "old_text": "Prototype",
                                                            "new_text": "Launch ready"])
            runtime.workspace = try XCTUnwrap(JSONDecoder().decode(
                [String: AskWorkspaceRef].self,
                from: Data(edited.content.utf8)
            )["workspace"])
            let review = try await invoke("project_files", ["action": "review", "workspace_id": id])
            return try XCTUnwrap(AskProjectReview.decode(review.content))
        }

        func start(_ script: String, service: Bool = false,
                   timeout: Double = 10) async throws -> AskProjectRuntimeLease {
            let result = try await invoke("project_terminal", ["action": "start", "workspace_id": runtime.workspace.id,
                                                               "expected_version": runtime.workspace.version,
                                                               "script": script, "service": service,
                                                               "timeout_seconds": timeout,
                                                               "readiness_timeout_seconds": 0.7])
            let receipt = try XCTUnwrap(AskProjectTerminalReceipt.decode(result.content))
            return try XCTUnwrap(tools.projectLeases[receipt.process.id])
        }

        func artifact(_ resources: [String]) async throws -> AskArtifactRef {
            let result = try await invoke("artifact", ["workspace_id": runtime.workspace.id,
                                                       "expected_version": runtime.workspace.version,
                                                       "entry": "index.html",
                                                       "resources": resources])
            return try XCTUnwrap(result.outcome?.artifacts?.first)
        }

        func export(_ ref: AskArtifactRef) throws -> [String: String] {
            let bundle = try tools.loadArtifact(
                ref,
                ownerId: runtime.scope.ownerId,
                conversationId: runtime.scope.conversationId
            )
            let url = runtime.base.appendingPathComponent("export-" + ref.id)
            try AskArtifactExport.write(bundle, to: url)
            return try ["id": ref.id, "hash": ref.sha256,
                        "opened_hash": AskToolPolicy.digest(XCTUnwrap(bundle.files[bundle.manifest.entry])),
                        "exported_hash": AskToolPolicy.digest(Data(contentsOf: url))]
        }
    }

    func cleanupEvidence(_ fixture: Fixture, _ lease: AskProjectRuntimeLease) throws -> (process: Bool, port: Bool) {
        let status = try fixture.runtime.runtime.status(lease, scope: fixture.runtime.scope)
        let reaped = ![.ready, .running, .starting]
            .contains(status.state) && kill(status.pid, 0) == -1 && errno == ESRCH
        guard let port = lease.port else { return (reaped, true) }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0); defer { Darwin.close(descriptor) }
        guard descriptor >= 0 else { return (reaped, false) }
        var address = AskProjectPortLease.address(port: port)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        } }
        return (reaped, result == -1 && errno == ECONNREFUSED)
    }

    func assertClean(_ fixture: Fixture, _ lease: AskProjectRuntimeLease) throws {
        let evidence = try cleanupEvidence(fixture, lease)
        XCTAssertTrue(evidence.process); XCTAssertTrue(evidence.port)
    }

    func testRealFrontendModificationTestPreviewArtifactsAndCleanup() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let review = try await fixture.edit()
        XCTAssertTrue(review.patch.contains("+<main>")); XCTAssertTrue(review.patch.contains("Launch ready"))
        let patch = try fixture.tools.exportProjectPatch(
            review.workspace,
            ownerId: "owner",
            conversationId: "conversation"
        )
        XCTAssertEqual(AskToolPolicy.digest(patch), review.patchHash)
        let test = try await fixture.start("check.py")
        let result = try await fixture.runtime.wait(test)
        XCTAssertEqual(result.state, .exited); XCTAssertEqual(result.exitCode, 0)
        try assertClean(fixture, test)
        let server = try await fixture.start("serve.py", service: true)
        let ready = try await fixture.runtime.wait(server, ready: true)
        XCTAssertEqual(ready.state, .ready)
        let paths = ["index.html", "app.js", "style.css"]
        let output = try await fixture.invoke("project_terminal", ["action": "preview", "lease_id": server.id,
                                                                   "entry": "index.html", "resources": paths])
        let receipt = try XCTUnwrap(AskProjectTerminalReceipt.decode(output.content))
        let evidence = try XCTUnwrap(receipt.previewEvidence)
        XCTAssertTrue(evidence.pageText.contains("Launch ready")); XCTAssertTrue(evidence.pageText
            .contains("JavaScript verified"))
        XCTAssertTrue(evidence.console.contains { $0.contains("Benchmark script loaded") }); XCTAssertEqual(
            evidence.errors,
            []
        )
        let artifact = try await fixture.artifact(paths)
        let exported = try ([artifact] + evidence.artifacts).map(fixture.export)
        XCTAssertTrue(exported.allSatisfy { $0["hash"] == $0["opened_hash"] && $0["hash"] == $0["exported_hash"] })
        _ = try await fixture.invoke("project_terminal", ["action": "stop", "lease_id": server.id])
        try assertClean(fixture, server)
        XCTAssertTrue(try String(contentsOf: fixture.runtime.source.appendingPathComponent("index.html"))
            .contains("Prototype"))
        try saveEvidence("frontend", fixture: fixture, review: review, result: result, evidence: evidence,
                         artifacts: exported, readiness: ready.state == .ready ? "nonce_verified" : "failed",
                         lease: server)
    }

    func testStaticPageCompletesWithoutAServiceOrPackageNetwork() async throws {
        let fixture = try Fixture(kind: "static"); defer { fixture.close() }
        let review = try await fixture.edit()
        let lease = try await fixture.start("check.py"), status = try await fixture.runtime.wait(lease)
        XCTAssertEqual(status.exitCode, 0); try assertClean(fixture, lease)
        let artifact = try await fixture.artifact(["index.html"])
        let host = AskPreviewHost(); defer { host.close() }
        let view = try await host.open(.artifact(artifact), enabled: true) { ref in
            try fixture.tools.loadArtifact(ref, ownerId: "owner", conversationId: "conversation")
        }
        view.frame = NSRect(x: 0, y: 0, width: 760, height: 480)
        try await AskProjectPreviewCapture.waitUntilLoaded(host)
        let text = try await view.evaluateJavaScript("document.body.innerText") as? String ?? ""
        XCTAssertTrue(text.contains("Launch ready")); XCTAssertTrue(text.contains("Offline static page verified"))
        let image = try await view.takeSnapshot(configuration: nil),
            png = try XCTUnwrap(AskArtifactActions.pngData(image))
        let diagnostics = try await host.collectDiagnostics()
        XCTAssertTrue(diagnostics.errors.isEmpty)
        let screenshot = try fixture.store.publish(
            files: ["preview.png": png],
            entry: "preview.png",
            scope: fixture.runtime.scope
        )
        let evidence = AskProjectPreviewEvidence(
            pageText: text,
            console: diagnostics.console,
            errors: diagnostics.errors,
            screenshotHash: AskToolPolicy.digest(png),
            artifacts: [screenshot]
        )
        try saveEvidence("static", fixture: fixture, review: review, result: status, evidence: evidence,
                         artifacts: [artifact, screenshot].map(fixture.export), readiness: "static_loaded", lease: lease)
    }

    func testFailingTestReadinessFailureConflictAndCancellationAreNotSuccess() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let failed = try await fixture.start("check.py"), status = try await fixture.runtime.wait(failed)
        XCTAssertEqual(status.exitCode, 1)
        let output = try await fixture.invoke("project_terminal", ["action": "status", "lease_id": failed.id])
        XCTAssertTrue(output.isError); XCTAssertEqual(output.outcome?.effectVerified, false)
        try assertClean(fixture, failed)
        try Data("import time; time.sleep(20)".utf8).write(to: fixture.runtime.source.appendingPathComponent("hang.py"))
        let badService = try await fixture.start("hang.py", service: true)
        let timedOut = try await fixture.runtime.wait(badService)
        XCTAssertEqual(timedOut.state, .readinessTimedOut); try assertClean(fixture, badService)
        do { _ = try fixture.tools.terminalPreview(
            badService.reference,
            entry: "index.html",
            resources: ["index.html"]
        ); XCTFail("Expected rejection") } catch {}
        _ = try await fixture.edit()
        try Data("human edit".utf8).write(to: fixture.runtime.source.appendingPathComponent("index.html"))
        do { _ = try await fixture.start("check.py"); XCTFail("Source conflict must deny execution") } catch {}
        XCTAssertEqual(
            try String(contentsOf: fixture.runtime.source.appendingPathComponent("index.html")),
            "human edit"
        )
        let fresh = try Fixture(); defer { fresh.close() }
        let server = try await fresh.start("serve.py", service: true)
        _ = try await fresh.runtime.wait(server, ready: true)
        fresh.tools.cancelProjects(conversationId: "conversation")
        XCTAssertEqual(try fresh.runtime.runtime.status(server, scope: fresh.runtime.scope).state, .cancelled)
        try assertClean(fresh, server)
    }

    private func saveEvidence(_ scenario: String, fixture: Fixture, review: AskProjectReview,
                              result: AskProjectProcessStatus, evidence: AskProjectPreviewEvidence,
                              artifacts: [[String: String]], readiness: String, lease: AskProjectRuntimeLease) throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_D04_EVIDENCE"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let cleanup = try cleanupEvidence(fixture, lease)
        let value: [String: Any] = [
            "scenario": scenario,
            "mode": "local",
            "workspace_version": review.workspace.version,
            "diff": review.patch,
            "test_exit_code": result.exitCode as Any,
            "readiness": readiness,
            "page_text": evidence.pageText,
            "screenshot_hash": evidence.screenshotHash,
            "console": evidence.console,
            "console_errors": evidence.errors,
            "artifacts": artifacts,
            "process_reaped": cleanup.process,
            "port_closed": cleanup.port
        ]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(scenario + ".json"))
        for ref in evidence.artifacts where ref.mediaType == "image/png" {
            let bundle = try fixture.tools.loadArtifact(ref, ownerId: "owner", conversationId: "conversation")
            try AskArtifactExport.write(
                bundle,
                to: URL(fileURLWithPath: directory).appendingPathComponent(scenario + ".png")
            )
        }
    }
}
