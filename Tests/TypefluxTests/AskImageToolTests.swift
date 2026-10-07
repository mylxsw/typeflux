import AppKit
@testable import Typeflux
import XCTest

actor ImageGeneratorStub: AskImageGenerating {
    var calls = 0
    var result: AskImageGenerationResult
    init(_ images: [AskGeneratedImageData]) {
        result = .init(images: images)
    }

    func generate(_: AskImageRequest, configuration _: AskImageConfiguration,
                  key _: String) async throws -> AskImageGenerationResult {
        calls += 1
        return result
    }
}

@MainActor
final class AskImageToolTests: XCTestCase {
    var base: URL!
    var store: AskArtifactStore!
    var tools: AskLocalTools!
    var generator: ImageGeneratorStub!
    var config: AskImageConfiguration? = .preset(.google)
    var key = "secret"
    let call = AskToolCall(
        id: "image-call",
        function: .init(name: "generate_image", arguments: #"{"prompt":"A blue bird"}"#)
    )

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("image-tool-" + UUID().uuidString)
        store = AskArtifactStore(storageURL: base.appendingPathComponent("artifacts"))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        tools = AskLocalTools(registry: MCPRegistry(settingsStore: .init(defaults: defaults)), artifactStore: store)
        tools.imageConfigurationOverride = { self.config.map { ($0, self.key) } }
        generator = try ImageGeneratorStub([AskGeneratedImageData(data: AskImageGenerationTests.picture())])
        tools.imageGenerator = generator
        tools.bindExecution(ownerId: "owner", conversationId: "conversation", runId: "run")
    }

    override func tearDownWithError() throws {
        tools.imageConfigurationOverride = nil
        try? FileManager.default.removeItem(at: base)
    }

    func testIndependentAvailabilityAndApprovalBinding() async throws {
        let enabled = await tools.definitions(conversationId: "conversation")
        XCTAssertTrue(enabled.contains { $0.name == "generate_image" })
        XCTAssertFalse(enabled.contains { $0.name == "artifact" })
        XCTAssertEqual(tools.risk(of: call), .write)
        XCTAssertFalse(AskToolPolicy.mayReuse(call))
        XCTAssertEqual(AskTheme.toolTitle(call), L("imagegen.title"))
        XCTAssertEqual(AskPresentation.toolSymbol(call), "photo.badge.plus")
        let original = try await tools.approvalBinding(for: call, conversationId: "conversation")
        for _ in 0 ..< 20 {
            let repeated = try await tools.approvalBinding(for: call, conversationId: "conversation")
            XCTAssertEqual(repeated, original, "Approval digests must be stable across request encoding")
        }
        XCTAssertEqual(original.target.kind, "network_origin")
        XCTAssertFalse(String(describing: original).contains("secret"))
        config?.model = "future-model"
        let changed = try await tools.approvalBinding(for: call, conversationId: "conversation")
        XCTAssertNotEqual(original, changed)
        key = "rotated"
        let rotated = try await tools.approvalBinding(for: call, conversationId: "conversation")
        XCTAssertNotEqual(changed, rotated)
        do { _ = try await tools.executeApproved(
            call,
            conversationId: "conversation",
            binding: original,
            authorize: {}
        ); XCTFail() } catch {}
        do { _ = try await tools.execute(call, conversationId: "conversation"); XCTFail() } catch {}
        let count = await generator.calls
        XCTAssertEqual(count, 0)
        config = nil
        let disabled = await tools.definitions(conversationId: "conversation")
        XCTAssertFalse(disabled.contains { $0.name == "generate_image" })
        do { _ = try await tools.approvalBinding(for: call, conversationId: "conversation"); XCTFail() } catch {}
    }

    func testGeneratePersistReopenLegacyProjectionAndOwnerIsolation() async throws {
        let binding = try await tools.approvalBinding(for: call, conversationId: "conversation")
        let output = try await tools.executeApproved(
            call,
            conversationId: "conversation",
            binding: binding,
            authorize: {}
        )
        let ref = try XCTUnwrap(output.outcome?.artifacts?.first)
        XCTAssertEqual(ref.cleanup, "device_persistent")
        XCTAssertNil(ref.expiresAt)
        XCTAssertFalse(output.content.contains("30 days"))
        store.now = { Date(timeIntervalSince1970: 4_000_000_000) }
        XCTAssertNil(output.image, "Generating images must not make a text model require vision")
        XCTAssertFalse(output.isError)
        XCTAssertFalse(output.content.contains("base64"))
        let receipt = try JSONDecoder().decode(AskGeneratedImageReceipt.self, from: Data(output.content.utf8))
        XCTAssertEqual(receipt.generatedImages, [ref])
        let bundle = try tools.loadArtifact(ref, ownerId: "owner", conversationId: "conversation")
        XCTAssertNil(bundle.manifest.workspace, "No project folder grant is needed")
        XCTAssertNotNil(bundle.files["generation.json"])
        XCTAssertThrowsError(try tools.loadArtifact(ref, ownerId: "other", conversationId: "conversation"))
        XCTAssertThrowsError(try tools.loadArtifact(ref, ownerId: "owner", conversationId: "other"))
        var result = AskToolResultRequest(
            runId: "run",
            deviceId: "device",
            toolCallId: call.id,
            content: "",
            isError: false
        )
        result.record(output)
        let cache = try AskConversationCache(url: base.appendingPathComponent("cache.sqlite"))
        try await cache.saveToolResult(result, owner: "owner")
        let saved = try await cache.toolResult(id: "run/" + call.id, owner: "owner")
        XCTAssertEqual(saved?.harness?.outcome?.artifacts, [ref])
        let group = AskActivityGroup(
            id: "g",
            messages: [.init(id: "a", role: "assistant", text: "", toolCalls: [call], createdAt: Date())]
        )
        for harness in [AskHarnessContract(version: 1, outcome: output.outcome), nil] {
            let message = AskMessage(
                id: "m",
                role: "tool",
                text: output.content,
                toolCallId: call.id,
                createdAt: Date(),
                harness: harness
            )
            XCTAssertEqual(AskActivity.outputs(group, results: [message]).storedArtifacts, [ref])
        }
        let reopened = AskArtifactStore(storageURL: store.storageURL)
        XCTAssertNoThrow(try reopened.load(
            ref,
            scope: .init(ownerId: "owner", conversationId: "conversation", runId: "run")
        ))
        try tools.deleteArtifacts(ownerId: "other", conversationId: "conversation")
        XCTAssertNoThrow(try tools.loadArtifact(ref, ownerId: "owner", conversationId: "conversation"))
        try tools.deleteArtifacts(ownerId: "owner", conversationId: "conversation")
        XCTAssertThrowsError(try tools.loadArtifact(ref, ownerId: "owner", conversationId: "conversation"))
    }

    func testRevokedApprovalNeverPublishesLateResults() async throws {
        let binding = try await tools.approvalBinding(for: call, conversationId: "conversation")
        var checks = 0
        do {
            _ = try await tools.executeApproved(call, conversationId: "conversation", binding: binding) {
                checks += 1
                if checks >= 3 {
                    throw CancellationError()
                }
            }
            XCTFail()
        } catch is CancellationError {} catch { XCTFail("\(error)") }
        let calls = await generator.calls
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.path))
    }

    func testCloudConversationApprovalReceiptAndDeletionWithRealImageTool() async throws {
        let api = AskTestAPI()
        let cache = try AskConversationCache(url: base.appendingPathComponent("cloud-cache.sqlite"))
        let library = try AskModelLibrary(
            defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
            automaticallyLoadsCatalog: false
        )
        let model = AskConversationModel(api: api, cache: cache, tools: tools, capture: AskTestCapture(),
                                         deviceId: "device", modelLibrary: library, session: { ("owner", "token") })
        defer { model.resetSession() }
        await api.setTool(call)
        model.launcherDraft.text = "Generate a blue bird"
        model.launcherDraft.includeScreenshot = false
        model.submitLauncher()
        for _ in 0 ..< 1000 where model.pendingApprovals.isEmpty {
            try await Task.sleep(for: .milliseconds(2))
        }
        let id = try XCTUnwrap(model.selected?.id)
        XCTAssertEqual(model.pendingApprovals[id], call)
        let before = await generator.calls
        XCTAssertEqual(before, 0)
        XCTAssertFalse(model.canAllowForConversation(id), "Paid generation always needs exact approval")
        model.approve(conversationId: id, allowed: true)
        for _ in 0 ..< 1000 where !model.busyIds.isEmpty {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(model.busyIds.isEmpty)
        let results = await api.results
        let result = try XCTUnwrap(results.first)
        XCTAssertFalse(result.isError)
        let receipt = try JSONDecoder().decode(AskGeneratedImageReceipt.self, from: Data(result.content.utf8))
        let ref = try XCTUnwrap(receipt.generatedImages.first)
        XCTAssertNoThrow(try tools.loadArtifact(ref, ownerId: "owner", conversationId: id))
        let cached = try await cache.toolResult(id: result.runId + "/" + result.toolCallId, owner: "owner")
        XCTAssertEqual(cached?.harness?.outcome?.artifacts, [ref])
        XCTAssertNotNil(cached?.harness?.approval?.consumedAt)
        XCTAssertFalse(model.selected?.messages.contains(where: \.hasImage) ?? true)
        await model.delete(id)
        XCTAssertThrowsError(try tools.loadArtifact(ref, ownerId: "owner", conversationId: id))
        let count = await generator.calls
        XCTAssertEqual(count, 1)
    }

    func testLocalEngineRoundTripDoesNotRequireVisionOrDuplicateResults() async throws {
        let engine = AskLocalEngine(directory: base.appendingPathComponent("local"))
        var conversation = try await engine.send(conversationId: "conversation", request: .init(
            id: "question",
            deviceId: "device",
            text: "Generate a bird",
            tools: [AskLocalTools.imageGenerationDefinition],
            modelRef: "custom:text-only"
        ), token: "")
        let run = try XCTUnwrap(conversation.run)
        conversation = try await engine.inferenceResult(conversationId: conversation.id, request: .init(
            runId: run.id,
            deviceId: "device",
            inferenceId: XCTUnwrap(run.inference?.id),
            content: "",
            toolCalls: [call],
            finishReason: "tool_calls"
        ), token: "")
        XCTAssertEqual(conversation.run?.status, "waiting_tool")
        tools.bindExecution(ownerId: "owner", conversationId: conversation.id, runId: run.id)
        let binding = try await tools.approvalBinding(for: call, conversationId: conversation.id)
        let output = try await tools.executeApproved(
            call,
            conversationId: conversation.id,
            binding: binding,
            authorize: {}
        )
        var receipt = AskToolResultRequest(
            runId: run.id,
            deviceId: "device",
            toolCallId: call.id,
            content: "",
            isError: false
        )
        receipt.record(output)
        let next = try await engine.result(conversationId: conversation.id, request: receipt, token: "")
        XCTAssertEqual(next.run?.status, "waiting_inference")
        XCTAssertFalse(next.messages.contains(where: \.hasImage))
        let again = try await engine.result(conversationId: conversation.id, request: receipt, token: "")
        XCTAssertEqual(again.revision, next.revision)
        let saved = try await AskLocalEngine(directory: base.appendingPathComponent("local")).conversation(
            id: conversation.id,
            token: ""
        )
        let message = try XCTUnwrap(saved.messages.first { $0.toolCallId == call.id })
        XCTAssertTrue(message.text.contains("generatedImages"))
        let count = await generator.calls
        XCTAssertEqual(count, 1)
    }
}
