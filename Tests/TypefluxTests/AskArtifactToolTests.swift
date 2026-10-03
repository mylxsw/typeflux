import SwiftUI
@testable import Typeflux
import XCTest

@MainActor final class AskArtifactToolTests: XCTestCase {
    func fixture(enabled: Bool) throws -> (AskProjectToolTests.Fixture, AskLocalTools, AskArtifactStore) {
        let fixture = try AskProjectToolTests.Fixture()
        let store = AskArtifactStore(storageURL: fixture.base.appendingPathComponent("artifacts"))
        let tools = AskLocalTools(
            registry: MCPRegistry(settingsStore: .init(defaults: UserDefaults(suiteName: UUID().uuidString)!)),
            settings: fixture.settings,
            projects: fixture.store,
            projectModeEnabled: true,
            artifactStore: store,
            artifactCreationEnabled: enabled
        )
        tools.bindExecution(ownerId: "owner", conversationId: "conversation", runId: "run")
        return (fixture, tools, store)
    }

    func call(_ workspace: AskWorkspaceRef) throws -> AskToolCall {
        try .init(
            id: "artifact-call",
            function: .init(name: "artifact", arguments: String(decoding: JSONSerialization.data(withJSONObject: [
                "workspace_id": workspace.id, "expected_version": workspace.version, "entry": "file.txt",
                "resources": ["file.txt"]
            ]), as: UTF8.self))
        )
    }

    func testCreationRequiresIndependentGateAndApprovedDispatch() async throws {
        let (fixture, tools, _) = try fixture(enabled: false)
        defer { fixture.cleanup() }
        let workspace = try await fixture.open()
        let call = try call(workspace)
        let definitions = await tools.definitions(conversationId: "conversation")
        XCTAssertFalse(definitions.contains { $0.name == "artifact" })
        XCTAssertFalse(tools.artifactPreviewEnabled)
        do { _ = try await tools.approvalBinding(for: call, conversationId: "conversation"); XCTFail() } catch {}
        do { _ = try await tools.execute(call, conversationId: "conversation"); XCTFail() } catch {}
    }

    func testApprovedCreationReopenLegacyCloudReceiptAndRevocation() async throws {
        let (fixture, tools, store) = try fixture(enabled: true)
        defer { fixture.cleanup() }
        let workspace = try await fixture.open()
        let call = try call(workspace)
        let definitions = await tools.definitions(conversationId: "conversation")
        XCTAssertTrue(definitions.contains { $0.name == "artifact" })
        XCTAssertEqual(tools.risk(of: call), .write)
        let binding = try await tools.approvalBinding(for: call, conversationId: "conversation")
        XCTAssertFalse(binding.allowsReuse)
        XCTAssertFalse(AskToolPolicy.mayReuse(call))
        var authorized = 0
        let output = try await tools.executeApproved(
            call,
            conversationId: "conversation",
            binding: binding,
            authorize: { authorized += 1 }
        )
        XCTAssertEqual(authorized, 1)
        let ref = try XCTUnwrap(output.outcome?.artifacts?.first)
        let receipt = try JSONDecoder().decode(AskArtifactReceipt.self, from: Data(output.content.utf8))
        XCTAssertEqual(receipt.artifact, ref)
        XCTAssertFalse(output.content.contains(fixture.root.path))
        let bundle = try tools.loadArtifact(ref, ownerId: "owner", conversationId: "conversation")
        XCTAssertEqual(bundle.files["file.txt"], Data("hello\n".utf8))
        XCTAssertNoThrow(try AskArtifactStore(storageURL: store.storageURL).load(
            ref,
            scope: .init(ownerId: "owner", conversationId: "conversation", runId: "run")
        ) { _ in })
        let group = AskActivityGroup(
            id: "group",
            messages: [.init(id: "m", role: "assistant", text: "", toolCalls: [call], createdAt: Date())]
        )
        for harness in [AskHarnessContract(version: 1, outcome: output.outcome), nil] {
            let message = AskMessage(
                id: "result",
                role: "tool",
                text: output.content,
                toolCallId: call.id,
                createdAt: Date(),
                runId: "run",
                harness: harness
            )
            let reopened = try JSONDecoder().decode(AskMessage.self, from: JSONEncoder().encode(message))
            XCTAssertEqual(AskActivity.outputs(group, results: [reopened]).storedArtifacts, [ref])
        }
        fixture.settings.askFileAccessFolders = []
        XCTAssertThrowsError(try tools.loadArtifact(ref, ownerId: "owner", conversationId: "conversation"))
        fixture.settings.askFileAccessFolders = [fixture.root.path]
        XCTAssertThrowsError(try tools.loadArtifact(ref, ownerId: "other", conversationId: "conversation"))
        XCTAssertThrowsError(try tools.loadArtifact(ref, ownerId: "owner", conversationId: "other"))
        XCTAssertNoThrow(try tools.loadArtifact(ref, ownerId: "owner", conversationId: "conversation"))
    }

    func testApprovalBindsEveryResourceVersionAndRejectsCancelledGrant() async throws {
        let (fixture, tools, store) = try fixture(enabled: true)
        defer { fixture.cleanup() }
        let workspace = try await fixture.open()
        let call = try call(workspace)
        let binding = try await tools.approvalBinding(for: call, conversationId: "conversation")
        do {
            _ = try await tools.executeApproved(
                call,
                conversationId: "conversation",
                binding: binding,
                authorize: { throw AskArtifactError.denied }
            )
            XCTFail()
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.path))
        try Data("edited after approval".utf8).write(to: fixture.root.appendingPathComponent("file.txt"))
        do { _ = try await tools.executeApproved(
            call,
            conversationId: "conversation",
            binding: binding,
            authorize: {}
        ); XCTFail() } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.path))
        let freshBinding = try await tools.approvalBinding(for: call, conversationId: "conversation")
        do {
            _ = try await tools.executeApproved(call, conversationId: "conversation", binding: freshBinding) {
                try Data("late source change".utf8).write(to: fixture.root.appendingPathComponent("file.txt"))
            }
            XCTFail("Late source changes must fail before publication")
        } catch { XCTAssertEqual(error as? AskProjectError, .conflict) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.path))
        for args: [String: Any] in [[:], ["workspace_id": workspace.id, "expected_version": workspace.version],
                                    [
                                        "workspace_id": workspace.id,
                                        "expected_version": "stale",
                                        "entry": "file.txt",
                                        "resources": ["file.txt"]
                                    ],
                                    [
                                        "workspace_id": workspace.id,
                                        "expected_version": workspace.version,
                                        "entry": "file.txt",
                                        "resources": ["../escape", "file.txt"]
                                    ]] {
            XCTAssertThrowsError(try tools.artifactBinding(args, conversationId: "conversation"))
        }
        XCTAssertThrowsError(try tools.executeArtifact(
            ["workspace_id": workspace.id, "expected_version": workspace.version],
            conversationId: "conversation"
        ))
    }

    func testStoredCardsRenderAlongsideExistingImageAndProjectResults() throws {
        let (fixture, _, store) = try fixture(enabled: true)
        defer { fixture.cleanup() }
        let ref = try store.publish(files: ["log.txt": Data("complete log".utf8)], entry: "log.txt",
                                    scope: .init(ownerId: "owner", conversationId: "conversation", runId: "run"))
        let outputs = AskRunOutputs(storedArtifacts: [ref])
        XCTAssertFalse(outputs.isEmpty)
        let view = AskRunOutputsView(outputs: outputs)
            .environment(\.askArtifactAccess, AskArtifactAccess(load: { _ in
                try store.load(ref, scope: .init(ownerId: "owner", conversationId: "conversation", runId: "run"))
            }))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let hosting = NSHostingView(rootView: view.padding().frame(width: 600))
            hosting.appearance = NSAppearance(named: appearance)
            hosting.frame = CGRect(x: 0, y: 0, width: 600, height: 210)
            hosting.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: image)
            XCTAssertGreaterThan(image.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ARTIFACT_SCREENSHOTS"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try image.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("artifact-\(appearance.rawValue).png"))
            }
        }
    }

    func testNativePreviewsHandleTruncationBinaryUnsupportedMimeAndBoundedImages() throws {
        let (fixture, _, store) = try fixture(enabled: true)
        defer { fixture.cleanup() }
        let picture = NSImage(size: NSSize(width: 3200, height: 800), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        let png = try XCTUnwrap(AskArtifactActions.pngData(picture))
        let destination = fixture.base.appendingPathComponent("screenshot.png")
        try AskArtifactActions.exportImage(picture, to: destination)
        XCTAssertNotNil(AskArtifactPresentation.image(try Data(contentsOf: destination)))
        XCTAssertThrowsError(try AskArtifactActions.exportImage(picture, to: fixture.base.appendingPathComponent("missing/file.png")))
        let thumbnail = try XCTUnwrap(AskArtifactPresentation.image(png))
        XCTAssertLessThanOrEqual(thumbnail.size.width, 1600)
        XCTAssertNil(AskArtifactPresentation.image(Data("not an image".utf8)))
        let cases = [("long.txt", Data(String(repeating: "text\n", count: 7000).utf8)),
                     ("bad.txt", Data([0xFF])), ("binary.zip", Data([1, 2, 3])),
                     ("image.png", png), ("bad.png", Data()), ("index.html", Data("<h1>disabled</h1>".utf8)),
                     ("data.json", Data("{}".utf8))]
        for (name, bytes) in cases {
            let ref = try store.publish(files: [name: bytes], entry: name,
                                        scope: .init(ownerId: "owner", conversationId: "conversation", runId: "run"))
            let bundle = try store.load(
                ref,
                scope: .init(ownerId: "owner", conversationId: "conversation", runId: "run")
            )
            let view = NSHostingView(rootView: AskArtifactPreviewView(bundle: bundle, access: .init(), close: {}))
            view.frame = CGRect(x: 0, y: 0, width: 760, height: 560)
            view.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            XCTAssertEqual(image.pixelsWide, 760)
        }
        for error in [AskArtifactError.unavailable, .denied, .invalid, .tooLarge, .unsupported,
                      .corrupt, .expired, .previewDisabled, .dynamicUnavailable] {
            XCTAssertFalse(error.localizedDescription.hasPrefix("ask.artifact.error."))
        }
    }

    func testSQLiteReceiptReopenAndSelectedSessionAccess() async throws {
        let (fixture, tools, _) = try fixture(enabled: true)
        defer { fixture.cleanup() }
        let workspace = try await fixture.open()
        let call = try call(workspace)
        let binding = try await tools.approvalBinding(for: call, conversationId: "conversation")
        let output = try await tools.executeApproved(
            call,
            conversationId: "conversation",
            binding: binding,
            authorize: {}
        )
        let ref = try XCTUnwrap(output.outcome?.artifacts?.first)
        var request = AskToolResultRequest(
            runId: "run",
            deviceId: "device",
            toolCallId: call.id,
            content: "",
            isError: false
        )
        request.record(output)
        let url = fixture.base.appendingPathComponent("cache.sqlite")
        let cache = try AskConversationCache(url: url)
        try await cache.saveToolResult(request, owner: "owner")
        let conversation = AskConversation(id: "conversation", title: "Artifact", revision: 1, updatedAt: Date(),
                                           messages: [request.message(step: 1, now: Date())])
        try await cache.save(conversation, owner: "owner")
        let reopened = try AskConversationCache(url: url)
        let saved = try await reopened.load(id: "conversation", owner: "owner")
        XCTAssertEqual(saved?.messages.first?.harness?.outcome?.artifacts, [ref])
        let reopenedRef = try XCTUnwrap(saved?.messages.first?.harness?.outcome?.artifacts?.first)
        XCTAssertNoThrow(try tools.loadArtifact(reopenedRef, ownerId: "owner", conversationId: "conversation"))
        let journal = try await reopened.toolResult(id: "run/" + call.id, owner: "owner")
        XCTAssertEqual(journal?.harness?.outcome?.artifacts, [ref])
        let otherOwner = try await reopened.load(id: "conversation", owner: "other")
        XCTAssertNil(otherOwner)
        let api = AskTestAPI()
        await api.seed(conversation)
        var account: String? = "owner"
        let model = try AskConversationModel(api: api, cache: reopened, tools: tools, capture: AskTestCapture(),
                                             deviceId: "device",
                                             defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                             session: { account.map { ($0, "token") } })
        XCTAssertThrowsError(try model.artifactAccess.load(ref))
        await model.select("conversation")
        XCTAssertNoThrow(try model.artifactAccess.load(ref))
        XCTAssertNoThrow(try model.artifactAccess.validate(ref))
        XCTAssertFalse(model.artifactAccess.htmlEnabled)
        let access = model.artifactAccess
        account = "other"
        XCTAssertThrowsError(try access.load(ref))
        XCTAssertThrowsError(try access.validate(ref))
        account = nil
        XCTAssertThrowsError(try access.load(ref))
        XCTAssertThrowsError(try access.validate(ref))
    }
}
