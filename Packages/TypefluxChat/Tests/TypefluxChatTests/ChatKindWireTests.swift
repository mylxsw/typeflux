import Foundation
import XCTest
@testable import TypefluxChat

/// Chat and work (GUL-460): summaries and conversations carry the kind and, for a
/// conversation a Mac runs, its host device; mobile sends always open chats.
final class ChatKindWireTests: XCTestCase {
    func testSummaryAndConversationDecodeKindAndHost() throws {
        let summary = try ChatCoding.decoder().decode(ChatConversationSummary.self, from: Data(#"""
        {"id":"a1","title":"Tidy downloads","updated_at":"2026-10-22T00:00:00Z","kind":"work",
         "host_device_id":"mac-1","host_device_name":"MacBook Pro"}
        """#.utf8))
        XCTAssertEqual(summary.id, "a1")
        XCTAssertTrue(summary.isWork)
        XCTAssertTrue(summary.isHostedElsewhere)
        XCTAssertEqual(summary.hostDeviceName, "MacBook Pro")

        let conversation = try ChatCoding.decoder().decode(ChatConversation.self, from: Data(#"""
        {"id":"b","title":"T","revision":3,"updated_at":"2026-10-22T00:00:00Z","messages":[],"kind":"chat",
         "host_device_id":"mac-1"}
        """#.utf8))
        XCTAssertFalse(conversation.isWork)
        XCTAssertTrue(conversation.isHostedElsewhere)
        XCTAssertNil(conversation.hostDeviceName)
    }

    func testOlderServersDecodeWithoutKindOrHost() throws {
        let summary = try ChatCoding.decoder().decode(ChatConversationSummary.self, from: Data(
            #"{"id":"a","title":"T","updated_at":"2026-10-22T00:00:00Z"}"#.utf8))
        XCTAssertNil(summary.kind)
        XCTAssertFalse(summary.isWork)
        XCTAssertFalse(summary.isHostedElsewhere)
        let empty = ChatConversationSummary(id: "a", title: "T", hostDeviceId: "")
        XCTAssertFalse(empty.isHostedElsewhere, "an empty host is no host")
    }

    func testMobileSendsAlwaysOpenChats() throws {
        let request = ChatSendRequest(deviceId: "phone", text: "Hello")
        let body = try JSONSerialization.jsonObject(with: ChatCoding.encoder().encode(request)) as? [String: Any]
        XCTAssertEqual(body?["kind"] as? String, "chat")
        XCTAssertEqual(body?["platform"] as? String, "iOS")
        XCTAssertEqual((body?["tools"] as? [Any])?.count, 0)
    }
}
