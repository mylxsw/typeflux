import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

@MainActor final class AskTerminalIntegrationTests: XCTestCase {
    typealias Fixture = AskProjectLoopTests.Fixture

    func testUTF8ByteBoundariesGapsDuplicatesAndTruncation() throws {
        let bytes = Data("a✅世界🙂z".utf8)
        for size in 1 ... bytes.count {
            var buffer = AskTerminalTextBuffer(), cursor = 0
            while cursor < bytes.count {
                let end = min(bytes.count, cursor + size)
                let page = AskTerminalOutput(
                    data: bytes.subdata(in: cursor ..< end),
                    offset: Int64(cursor),
                    nextCursor: Int64(end),
                    lostBytes: 0
                )
                try buffer.append(page, final: end == bytes.count)
                try buffer.append(page, final: end == bytes.count)
                cursor = end
            }
            XCTAssertEqual(buffer.text, "a✅世界🙂z"); XCTAssertEqual(buffer.cursor, Int64(bytes.count))
        }
        var buffer = AskTerminalTextBuffer()
        try buffer.append(.init(data: Data([0xE2]), offset: 0, nextCursor: 1, lostBytes: 0), final: false)
        try buffer.append(.init(data: Data("tail".utf8), offset: 6, nextCursor: 10, lostBytes: 5), final: true)
        XCTAssertEqual(buffer.lostBytes, 5); XCTAssertTrue(buffer.text.contains("[Lost 5 output bytes]"))
        XCTAssertTrue(buffer.text.hasSuffix("tail"))
        XCTAssertThrowsError(try buffer.append(
            .init(data: Data(), offset: 20, nextCursor: 20, lostBytes: 0),
            final: true
        ))
        XCTAssertThrowsError(try buffer.append(
            .init(data: Data([1]), offset: 10, nextCursor: 12, lostBytes: 0),
            final: true
        ))
        var invalid = AskTerminalTextBuffer()
        try invalid.append(.init(data: Data([0xF0]), offset: 0, nextCursor: 1, lostBytes: 0), final: true)
        XCTAssertEqual(invalid.text, "�")
        var large = AskTerminalTextBuffer()
        try large.append(
            .init(data: Data(repeating: 65, count: 70000), offset: 0, nextCursor: 70000, lostBytes: 0),
            final: true
        )
        XCTAssertTrue(large.truncated); XCTAssertLessThan(large.text.utf8.count, 65536)
    }

    func testGateApprovalFullRequestInputEOFAndActualExit() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let disabled = AskLocalTools(registry: MCPRegistry(settingsStore: .init(defaults: fixture.settings.defaults)),
                                     settings: fixture.settings, projects: fixture.runtime.projects,
                                     projectModeEnabled: true)
        disabled.bindExecution(ownerId: "owner", conversationId: "conversation", runId: "run")
        let definitions = await disabled.definitions(conversationId: "conversation")
        XCTAssertFalse(definitions.contains { $0.name == "project_terminal" })
        let available = await fixture.tools.definitions(conversationId: "conversation")
        XCTAssertTrue(available.contains { $0.name == "project_terminal" })
        let args: [String: Any] = ["action": "start", "workspace_id": fixture.runtime.workspace.id,
                                   "expected_version": fixture.runtime.workspace.version, "script": "main.py",
                                   "cwd": ".",
                                   "arguments": ["argument"], "terminal": "pipe", "service": false,
                                   "timeout_seconds": 30.0, "readiness_timeout_seconds": 2.0]
        let call = try fixture.call("project_terminal", args)
        do { _ = try await fixture.tools.execute(call, conversationId: "conversation"); XCTFail("Expected rejection")
        } catch {}
        do {
            _ = try await disabled
                .approvalBinding(for: call, conversationId: "conversation"); XCTFail("Expected rejection")
        } catch {}
        let binding = try await fixture.tools.approvalBinding(for: call, conversationId: "conversation")
        XCTAssertTrue(binding.summary.contains("timeout"), binding.summary)
        XCTAssertEqual(
            binding.target.path,
            AskProjectFileAccess.normalizedRoot(fixture.runtime.source.path),
            binding.summary
        )
        XCTAssertFalse(binding.allowsReuse); XCTAssertFalse(AskToolPolicy.mayReuse(call))
        if case let .content(text) = AskApprovalPresentation.preview(call) {
            XCTAssertTrue(text.contains("offline")); XCTAssertTrue(text
                .contains("readinessTimeout")); XCTAssertTrue(text.contains("cwd"))
        } else {
            XCTFail("Expected rejection")
        }
        do {
            _ = try await fixture.tools
                .executeApproved(call, conversationId: "conversation", binding: binding) { throw CancellationError() }
            XCTFail("Expected rejection")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(fixture.tools.projectLeases.isEmpty)
        try Data("import sys; print(sys.stdin.read())".utf8)
            .write(to: fixture.runtime.source.appendingPathComponent("main.py"))
        let lease = try await fixture.start("main.py")
        _ = try await fixture.invoke(
            "project_terminal",
            ["action": "input", "lease_id": lease.id, "text": "Hello ✅", "eof": true]
        )
        let status = try await fixture.runtime.wait(lease)
        XCTAssertEqual(status.exitCode, 0)
        let output = try await fixture.invoke("project_terminal", ["action": "output", "lease_id": lease.id])
        let receipt = try XCTUnwrap(AskProjectTerminalReceipt.decode(output.content))
        XCTAssertTrue(receipt.text.contains("Hello ✅")); XCTAssertTrue(output.outcome?.effectVerified == true)
        do { _ = try await fixture.invoke(
            "project_terminal",
            ["action": "input", "lease_id": lease.id, "eof": true]
        ); XCTFail("Expected rejection") } catch {}
    }

    func testInvalidArgumentsUnknownHandlesAndPreviewErrorsFailClosed() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        for args: [String: Any] in [[:], ["script": "../x"], ["script": "x", "terminal": "shell"],
                                    ["script": "x", "arguments": true], ["script": "x", "cwd": true], [
                                        "script": "x",
                                        "timeout_seconds": "x"
                                    ],
                                    ["script": "x", "timeout_seconds": -1], [
                                        "script": "x",
                                        "readiness_timeout_seconds": "x"
                                    ], ["script": "x", "service": "true"]] {
            XCTAssertThrowsError(try AskLocalTools.launchRequest(args))
        }
        for args: [String: Any] in [[:], ["action": "unknown"], ["action": "start", "script": "x"],
                                    ["action": "status"], ["action": "status", "lease_id": "forged"]] {
            let call = try fixture.call("project_terminal", args)
            do {
                _ = try await fixture.tools
                    .approvalBinding(for: call, conversationId: "conversation"); XCTFail("Expected rejection")
            } catch {}
        }
        let lease = try await fixture.start("serve.py", service: true)
        _ = try await fixture.runtime.wait(lease, ready: true)
        do { _ = try await fixture.invoke("project_terminal", [
            "action": "preview",
            "lease_id": lease.id
        ]); XCTFail("Expected rejection") } catch {}
        let huge = try fixture.call(
            "project_terminal",
            ["action": "input", "lease_id": lease.id, "text": String(repeating: "x", count: 65537)]
        )
        do {
            _ = try await fixture.tools
                .approvalBinding(for: huge, conversationId: "conversation"); XCTFail("Expected rejection")
        } catch {}
        fixture.tools.cancelProjects(conversationId: nil)
        XCTAssertThrowsError(try fixture.tools.terminalStatus(lease.reference))
    }

    func testLiveCardAndStoppedEvidenceRenderInBothAppearances() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let lease = try await fixture.start("serve.py", service: true)
        _ = try await fixture.runtime.wait(lease, ready: true)
        var receipt = try fixture.tools.terminalStatus(lease.reference)
        receipt.previewEntry = "index.html"; receipt.previewResources = ["index.html", "app.js", "style.css"]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let access = AskTerminalAccess(status: { _ in receipt }, stop: fixture.tools.stopTerminal,
                                           preview: fixture.tools.terminalPreview)
            let card = NSHostingView(rootView: AskProjectTerminalCard(receipt: receipt)
                .environment(\.askTerminalAccess, access).padding().frame(width: 640))
            card.appearance = NSAppearance(named: appearance); card.frame = NSRect(x: 0, y: 0, width: 640, height: 340)
            card.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(card.bitmapImageRepForCachingDisplay(in: card.bounds))
            card.cacheDisplay(in: card.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_D04_EVIDENCE"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("terminal-" + appearance.rawValue + ".png"))
            }
        }
        try fixture.tools.stopTerminal(lease.reference)
        var stopped = try fixture.tools.terminalStatus(lease.reference)
        stopped.lostBytes = 12; stopped.truncated = true; stopped.status.persistenceFailed = true
        XCTAssertEqual(stopped.status.state, .stopped)
        let card = NSHostingView(rootView: AskProjectTerminalCard(receipt: stopped))
        card.frame = NSRect(x: 0, y: 0, width: 640, height: 200); card.layoutSubtreeIfNeeded()
        XCTAssertNotNil(card.bitmapImageRepForCachingDisplay(in: card.bounds))
    }

    func testPreviewFailureAndCancelledReadNeverPublishSuccess() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        try Data("<h1>broken</h1><script>throw new Error('broken preview')</script>".utf8)
            .write(to: fixture.runtime.source.appendingPathComponent("index.html"))
        let lease = try await fixture.start("serve.py", service: true)
        _ = try await fixture.runtime.wait(lease, ready: true)
        do {
            _ = try await fixture.invoke("project_terminal", ["action": "preview", "lease_id": lease.id,
                                                               "entry": "index.html", "resources": ["index.html"]])
            XCTFail("A broken page must not publish successful preview evidence")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.storageURL.path))
        let preview = try fixture.tools.terminalPreview(lease.reference, entry: "index.html", resources: ["index.html"])
        defer { preview.close() }
        let task = Task { @MainActor in try await preview.load("index.html") }
        task.cancel()
        do { _ = try await task.value; XCTFail("A cancelled resource read must fail") } catch {}
    }

    func testSelectedAccountAccessAndModelStopUseTrustedHandles() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        var lease = try await fixture.start("serve.py", service: true)
        _ = try await fixture.runtime.wait(lease, ready: true)
        let api = AskTestAPI()
        let conversation = AskConversation(id: "conversation", title: "Project", revision: 1, updatedAt: Date(), messages: [])
        await api.seed(conversation)
        var owner: String? = "owner"
        let model = try AskConversationModel(api: api, cache: AskConversationCache(url: fixture.runtime.base.appendingPathComponent("cache.sqlite")),
            tools: fixture.tools, capture: AskTestCapture(), deviceId: "device",
            defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), session: { owner.map { ($0, "token") } })
        XCTAssertThrowsError(try model.terminalAccess.status(lease.reference))
        await model.select("conversation")
        fixture.tools.bindExecution(ownerId: "owner", conversationId: "conversation", runId: "run")
        lease = try await fixture.start("serve.py", service: true)
        _ = try await fixture.runtime.wait(lease, ready: true)
        XCTAssertEqual(try model.terminalAccess.status(lease.reference).status.state, .ready)
        let preview = try model.terminalAccess.preview(lease.reference, "index.html", ["index.html"])
        preview.close()
        let access = model.terminalAccess
        owner = "another"
        XCTAssertThrowsError(try access.status(lease.reference))
        XCTAssertThrowsError(try access.stop(lease.reference))
        XCTAssertThrowsError(try access.preview(lease.reference, "index.html", ["index.html"]))
        owner = "owner"
        try access.stop(lease.reference)
        XCTAssertEqual(try access.status(lease.reference).status.state, .stopped)
        let second = try await fixture.start("serve.py", service: true)
        _ = try await fixture.runtime.wait(second, ready: true)
        model.stop(id: "conversation")
        XCTAssertEqual(try fixture.tools.terminalStatus(second.reference).status.state, .cancelled)
        model.resetSession()
        XCTAssertThrowsError(try fixture.tools.terminalStatus(second.reference))
    }

    func testPrivateConversationKeepsAccountLeaseAcrossRoutedToolDispatch() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let cloud = AskTestAPI(), local = AskTestAPI()
        let cache = try AskConversationCache(url: fixture.runtime.base.appendingPathComponent("private.sqlite"))
        let model = AskConversationModel(api: AskRoutedAPI(cloud: cloud, local: local), cache: cache,
                                         tools: fixture.tools, capture: AskTestCapture(), deviceId: "device",
                                         defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                         session: { ("owner", "cloud-token") })
        var conversation = AskConversation(id: "conversation", title: "Private project", revision: 1,
                                            updatedAt: Date(), messages: [])
        await local.seed(conversation)
        await model.refreshHistory()
        XCTAssertTrue(model.isLocal(conversation.id))
        fixture.tools.bindExecution(ownerId: "owner", conversationId: "conversation", runId: "run")
        let lease = try await fixture.start("serve.py", service: true)
        _ = try await fixture.runtime.wait(lease, ready: true)
        let call = try fixture.call("project_terminal", ["action": "status", "lease_id": lease.id])
        conversation.messages = [.init(id: "assistant", role: "assistant", text: "", toolCalls: [call], createdAt: Date())]
        conversation.run = .init(id: "run", deviceId: "device", status: "waiting_tool", steps: 1,
                                 updatedAt: Date(), tools: [AskLocalTools.terminalDefinition], pending: [call])
        await local.seed(conversation)
        await model.select(conversation.id)
        model.resume()
        for _ in 0 ..< 200 where !model.busyIds.isEmpty {
            if model.pendingApprovals[conversation.id] != nil {
                model.approve(conversationId: conversation.id, allowed: true)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.busyIds.isEmpty)
        let results = await local.results, cloudResults = await cloud.results
        XCTAssertEqual(results.count, 1); XCTAssertTrue(cloudResults.isEmpty)
        let receipt = try XCTUnwrap(AskProjectTerminalReceipt.decode(XCTUnwrap(results.first).content))
        XCTAssertEqual(receipt.process.ownerId, "owner")
        XCTAssertEqual(receipt.status.state, .ready)
        XCTAssertEqual(try model.terminalAccess.status(lease.reference).status.state, .ready)
        model.stop(id: conversation.id)
        XCTAssertEqual(try fixture.tools.terminalStatus(lease.reference).status.state, .cancelled)
        model.resetSession()
    }
}
