import Foundation
@testable import TypefluxChat
import XCTest

final class ChatLocalConversationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTitleUsesTheFirstLineAndIsBounded() {
        XCTAssertEqual(ChatLocalConversation.title(for: "  Plan a trip  \nmore"), "Plan a trip")
        let long = String(repeating: "a", count: 60)
        XCTAssertEqual(ChatLocalConversation.title(for: long), String(repeating: "a", count: 40) + "…")
        XCTAssertEqual(ChatLocalConversation.title(for: ""), "")
    }

    func testSystemPromptStatesTheDateAndLimits() {
        let prompt = ChatLocalConversation.system(now: now, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(prompt.contains("2027-01-15"))
        XCTAssertTrue(prompt.contains("cannot browse"))
    }

    func testBeginStreamAndFinishBuildAnAnswer() throws {
        var value = ChatLocalConversation.begin(nil, id: "c1", text: "Hello there", image: "data:image/png;base64,AA",
                                                modelRef: "local:p/m", deviceID: "phone", now: now)
        XCTAssertEqual(value.title, "Hello there")
        XCTAssertEqual(value.messages.map(\.role), ["user"])
        XCTAssertEqual(value.run?.status, "running")
        XCTAssertEqual(value.run?.modelRef, "local:p/m")
        XCTAssertTrue(value.run?.isActive == true)
        XCTAssertEqual(value.revision, 1)

        value = ChatLocalConversation.progress(value, text: "Hi", reasoning: "think", started: now,
                                               now: now.addingTimeInterval(2))
        XCTAssertEqual(value.run?.preview, "Hi")
        XCTAssertEqual(value.run?.reasoningMilliseconds, 2000)

        value = ChatLocalConversation.finish(value, status: "completed", text: "Hi!", reasoning: "think",
                                             reasoningMilliseconds: 2000, now: now)
        XCTAssertEqual(value.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(value.messages.last?.modelRef, "local:p/m")
        XCTAssertEqual(value.messages.last?.reasoningMilliseconds, 2000)
        XCTAssertNil(value.run?.preview)
        XCTAssertFalse(value.run?.isActive == true)

        let turns = ChatLocalConversation.providerMessages(value)
        XCTAssertEqual(turns.map(\.role), ["user", "assistant"])
        XCTAssertEqual(turns.first?.image, "data:image/png;base64,AA")
        XCTAssertNil(turns.last?.image)
    }

    func testFollowUpKeepsTheTitleAndHistory() {
        let first = ChatLocalConversation.finish(
            ChatLocalConversation.begin(nil, id: "c1", text: "First", image: nil, modelRef: "local:p/m",
                                        deviceID: "d", now: now),
            status: "completed", text: "Answer", reasoning: "", reasoningMilliseconds: nil, now: now)
        let second = ChatLocalConversation.begin(first, id: "ignored", text: "Second", image: nil,
                                                 modelRef: "local:p/n", deviceID: "d", now: now)
        XCTAssertEqual(second.id, "c1")
        XCTAssertEqual(second.title, "First")
        XCTAssertEqual(second.messages.map(\.text), ["First", "Answer", "Second"])
        XCTAssertEqual(second.run?.modelRef, "local:p/n")
    }

    func testFailureWithoutTextKeepsOnlyTheRunError() {
        let started = ChatLocalConversation.begin(nil, id: "c1", text: "Q", image: nil, modelRef: "local:p/m",
                                                  deviceID: "d", now: now)
        let failed = ChatLocalConversation.finish(started, status: "failed", text: "", reasoning: "",
                                                  reasoningMilliseconds: nil, error: "Nope", now: now)
        XCTAssertEqual(failed.messages.count, 1)
        XCTAssertEqual(failed.run?.status, "failed")
        XCTAssertEqual(failed.run?.error, "Nope")
        let retried = ChatLocalConversation.running(failed, modelRef: "local:p/m", deviceID: "d", now: now)
        XCTAssertEqual(retried.run?.status, "running")
        XCTAssertNil(retried.run?.error)
    }

    func testRegenerateRemovesOnlyTheChosenAnswer() {
        let answered = ChatLocalConversation.finish(
            ChatLocalConversation.begin(nil, id: "c1", text: "Q", image: nil, modelRef: "local:p/m",
                                        deviceID: "d", now: now),
            status: "completed", text: "A", reasoning: "", reasoningMilliseconds: nil, now: now)
        let answerID = answered.messages[1].id
        let again = ChatLocalConversation.regenerate(answered, messageID: answerID, modelRef: "local:p/m",
                                                     deviceID: "d", now: now)
        XCTAssertEqual(again?.messages.map(\.role), ["user"])
        XCTAssertEqual(again?.run?.status, "running")
        XCTAssertNil(ChatLocalConversation.regenerate(answered, messageID: answered.messages[0].id,
                                                      modelRef: "local:p/m", deviceID: "d"))
        XCTAssertNil(ChatLocalConversation.regenerate(answered, messageID: "missing", modelRef: "m", deviceID: "d"))
    }

    func testProviderMessagesSkipErrorsAndEmptyTurns() {
        let value = ChatConversation(id: "c", title: "t", messages: [
            ChatMessage(id: "1", role: "user", text: "Q"),
            ChatMessage(id: "2", role: "assistant", text: "", isError: nil),
            ChatMessage(id: "3", role: "assistant", text: "broken", isError: true),
            ChatMessage(id: "4", role: "tool", text: "result"),
        ])
        XCTAssertEqual(ChatLocalConversation.providerMessages(value).map(\.text), ["Q"])
    }

    func testConversationDocumentsRoundTripThroughTheWireCoding() throws {
        let original = ChatConversation(
            id: "6F9619FF-8B86-D011-B42D-00C04FC964FF", title: "Doc", revision: 3, updatedAt: now,
            messages: [ChatMessage(id: "m", role: "assistant", text: "A", createdAt: now, reasoning: "R",
                                   reasoningMilliseconds: 12,
                                   attachments: [ChatAttachment(kind: "image", id: "a", name: "n",
                                                                image: "data:image/png;base64,AA")],
                                   toolCalls: [ChatToolCall(id: "t", type: "function",
                                                            function: .init(name: "f", arguments: "{}"))],
                                   modelRef: "local:p/m")],
            run: ChatRun(id: "r", deviceId: "d", status: "completed", updatedAt: now, preview: "p",
                         reasoning: "x", reasoningMilliseconds: 5, error: "e", modelRef: "cloud:fast")
        )
        let data = try ChatCoding.encoder().encode(original)
        let decoded = try ChatCoding.decoder().decode(ChatConversation.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, "6f9619ff-8b86-d011-b42d-00c04fc964ff")
    }

    func testServerRunModelIsDecoded() throws {
        let json = #"{"id":"r","device_id":"d","status":"running","updated_at":"2026-10-18T00:00:00Z","model_ref":"cloud:default"}"#
        let run = try ChatCoding.decoder().decode(ChatRun.self, from: Data(json.utf8))
        XCTAssertEqual(run.modelRef, "cloud:default")
        XCTAssertEqual(run.pending, [])
    }

    func testAccountDetailsRoundTripForTheCache() throws {
        let usage = ChatCreditUsage(periodEnd: now, planCode: "pro", paid: true,
                                    credits: .init(limit: 10, used: 4, remaining: 6, addon: .init(remaining: 3)))
        let profile = ChatProfile(id: "u", email: "a@example.com", name: "A", providers: ["apple"])
        XCTAssertEqual(try ChatCoding.decoder().decode(ChatCreditUsage.self,
                                                       from: ChatCoding.encoder().encode(usage)), usage)
        XCTAssertEqual(try ChatCoding.decoder().decode(ChatProfile.self,
                                                       from: ChatCoding.encoder().encode(profile)), profile)
    }
}

final class ChatConnectivityTests: XCTestCase {
    func testNetworkErrorsAreClassified() {
        XCTAssertEqual(ChatConnectivity.classify(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(ChatConnectivity.classify(URLError(.networkConnectionLost)), .offline)
        XCTAssertEqual(ChatConnectivity.classify(URLError(.timedOut)), .serviceUnavailable)
        XCTAssertEqual(ChatConnectivity.classify(URLError(.cannotConnectToHost)), .serviceUnavailable)
        XCTAssertEqual(ChatConnectivity.classify(URLError(.unknown)), .serviceUnavailable)
        XCTAssertNil(ChatConnectivity.classify(URLError(.cancelled)))
    }

    func testServerFailuresAreOutagesButRefusalsAreNot() {
        XCTAssertEqual(ChatConnectivity.classify(ChatAPIError.server(code: "HTTP_502", message: nil)),
                       .serviceUnavailable)
        XCTAssertEqual(ChatConnectivity.classify(ChatAPIError.server(code: "INTERNAL_ERROR", message: nil)),
                       .serviceUnavailable)
        XCTAssertNil(ChatConnectivity.classify(ChatAPIError.server(code: "HTTP_404", message: nil)))
        XCTAssertNil(ChatConnectivity.classify(ChatAPIError.server(code: "CREDITS_EXHAUSTED", message: nil)))
        XCTAssertNil(ChatConnectivity.classify(ChatAPIError.unauthorized))
        XCTAssertNil(ChatConnectivity.classify(CancellationError()))
    }
}
