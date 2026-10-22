import AppKit
import Testing
import TypefluxChatWindowProtocol
@testable import TypefluxChatWindowRuntime

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct ChatWindowPresentationTests {
    @Test func mainActorRendersAcknowledgesHidesAndRejectsStalePresentation() throws {
        _ = NSApplication.shared
        let view = ChatWindowPresentation(offscreen: true), generation = UUID()
        defer { view.window?.close() }
        #expect(try view.receive(.init(generation: generation, kind: .hello)).kind == .ready)
        let snapshot = ChatWindowSnapshot(sequence: 1, title: "Synthetic chat", messages: [.init(role: .user, text: "Question"), .init(role: .assistant, text: "Answer")])
        #expect(try view.receive(.init(generation: generation, kind: .present, snapshot: snapshot)).sequence == 1)
        #expect(view.window?.isVisible == true)
        #expect(view.window?.title == "Synthetic chat" && view.text?.string == "Question\n\nAnswer")
        #expect(view.text?.isEditable == false)
        #expect(throws: ChatWindowFailure.invalidProtocol) { try view.receive(.init(generation: UUID(), kind: .present, snapshot: snapshot)) }
        #expect(view.text?.string == "Question\n\nAnswer")
        #expect(try view.receive(.init(generation: generation, kind: .ping)).kind == .pong)
        _ = try view.receive(.init(generation: generation, kind: .hide))
        #expect(view.window?.isVisible == false)
        _ = try view.receive(.init(generation: generation, kind: .shutdown))
    }
}
