import Foundation
import Testing
@testable import Typeflux

/// Explicit opt-in: uses the signed-in account and the real paid image provider.
@Suite(.serialized, .exclusiveUIState)
@MainActor struct AskCloudImageLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_LIVE_IMAGE_VERIFY_FILE"] != nil))
    func workModeWithRealCloudInferenceGeneratesAndPersistsImage() async throws {
        let sessionFile = try #require(ProcessInfo.processInfo.environment["TYPEFLUX_LIVE_IMAGE_VERIFY_FILE"])
        let token = try String(contentsOfFile: sessionFile, encoding: .utf8)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("typeflux-live-work-image-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = AskDeviceBuiltinHost(transport: AskDeviceTransport(), token: { token })
        let engine = AskLocalEngine(directory: root, builtinTools: host, allowsCloudModels: true)
        let id = UUID().uuidString.lowercased(), device = UUID().uuidString.lowercased()
        var request = AskSendRequest(id: UUID().uuidString, deviceId: device,
            text: "生成一张小猫吸狗的图片，小猫贴着小狗的鼻子，温馨插画。只需要一张。", tools: [], modelRef: "cloud:default")
        request.kind = "work"; request.clientToolApproval = true
        var conversation = try await engine.send(conversationId: id, request: request, token: "")
        #expect(conversation.run?.cloudTools?.contains { $0.name == "image_generate" } == true)
        let client = AskDeviceModelClient()
        var imageCalls = 0
        for _ in 0..<8 {
            let run = try #require(conversation.run)
            if run.status == "completed" { break }
            if run.status == "waiting_tool", let call = run.pending.first {
                #expect(call.function.name == "image_generate")
                imageCalls += 1
                #expect(imageCalls == 1)
                conversation = try await engine.result(conversationId: id, request: .init(approveExecution: true,
                    runId: run.id, deviceId: device, toolCallId: call.id, content: "", isError: false), token: "")
            } else {
                let inference = try #require(run.inference)
                let reply = try await AskDeviceModelClient.$billingKey.withValue(AskDeviceModelClient.receiptKey(inference.id)) {
                    try await client.complete(provider: .init(id: "cloud", name: "Cloud", remote: .typefluxCloud),
                        connection: .init(provider: .typefluxCloud, baseURL: "", model: "default", apiKey: token),
                        payload: inference.payload, onUsage: nil, onProgress: nil)
                }
                conversation = try await engine.inferenceResult(conversationId: id, request: .init(runId: run.id,
                    deviceId: device, inferenceId: inference.id, content: reply.0, toolCalls: reply.1,
                    usage: .init(promptTokens: 0, completionTokens: 0, totalTokens: 0)), token: "")
            }
        }
        #expect(conversation.run?.status == "completed")
        #expect(imageCalls == 1)
        let images = conversation.messages.compactMap(\.generatedImage)
        #expect(images.count == 1)
        #expect(images.first?.safeURL != nil)
        let record = try AskCoding.encoder().encode(conversation)
        try record.write(to: URL(fileURLWithPath: "/tmp/typeflux-live-work-image-result.json"), options: .atomic)
    }
}
