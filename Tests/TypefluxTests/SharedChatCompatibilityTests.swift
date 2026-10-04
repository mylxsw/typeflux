import Foundation
import Testing
import TypefluxChat
@testable import Typeflux

@Suite("Shared chat compatibility")
struct SharedChatCompatibilityTests {
    @Test func desktopSnapshotDecodesToMobileProjectionWithoutPublishingTools() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let call = AskToolCall(id: "call", function: .init(name: "computer", arguments: "{}"))
        let run = AskRun(id: "run", deviceId: "mac", status: "waiting_tool", steps: 1,
                         updatedAt: timestamp, tools: [], pending: [call])
        let desktop = AskConversation(id: UUID().uuidString, title: "Desktop", revision: 2,
            updatedAt: timestamp,
            messages: [.init(id: "message", role: "user", text: "Question", createdAt: timestamp)],
            run: run)
        let mobile = try ChatCoding.decoder().decode(ChatConversation.self, from: AskCoding.encoder().encode(desktop))
        #expect(mobile.id == desktop.id)
        #expect(mobile.messages.first?.text == "Question")
        #expect(mobile.run?.requiresDesktop == true)
        #expect(mobile.run?.pending.first == call)
        let request = ChatSendRequest(deviceId: "phone", text: "Follow-up")
        let payload = try #require(JSONSerialization.jsonObject(with: ChatCoding.encoder().encode(request)) as? [String: Any])
        #expect(payload["platform"] as? String == "iOS")
        #expect(payload["tools"] as? [String] == [])
    }

    @Test func sharedFrameErrorsRetainDesktopErrorContract() throws {
        var frame = AskSSEFrame(limit: 2)
        _ = try frame.push(255)
        #expect(throws: AskStreamError.self) { try frame.push(10) }
        #expect(throws: AskStreamError.self) { try frame.append("data: exceeds limit") }
    }
}
