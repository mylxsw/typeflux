import Foundation
import XCTest
@testable import Typeflux

extension AskPromptBuilderTests {
    func testMemoryProvenanceAndSourceExpiryRemainReadOnly() {
        let date = Date(timeIntervalSince1970: 1)
        for expired in [false, true] {
            var conversation = AskConversation(id: "provenance", title: "Synthetic", revision: 1,
                updatedAt: date, messages: [])
            conversation.memory = AskMemory(global: "Explicit saved correction", owner: "synthetic-prompt-port-owner",
                capturedAt: date, sources: [.init(id: "private-source-id", source: .correction,
                    owner: "synthetic-prompt-port-owner", scope: "account", version: 2, createdAt: date,
                    updatedAt: date, expiry: expired ? date : nil, supersedes: "old-source-id")])
            let original = conversation
            let payload = DefaultAskPromptBuilder().conversation(.init(conversation: conversation, tools: [],
                localDate: "", timeZone: nil, locale: nil, typedContentEnabled: false))
            let raw = AskLocalPrompt.json(payload)
            XCTAssertEqual(raw.contains("<user_memory>"), !expired)
            XCTAssertFalse(raw.contains("private-source-id"))
            XCTAssertFalse(raw.contains("synthetic-prompt-port-owner"))
            XCTAssertEqual(conversation, original)
        }
    }
}
