import Foundation
import Testing
@testable import Typeflux

@Suite("Ask conversation workspaces")
struct AskConversationWorkspaceTests {
    @Test func capturesOriginalInputsAndKeepsChatsSeparate() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ask-workspace-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = AskConversationWorkspaceStore(rootURL: base.appendingPathComponent("regular"))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("original.txt")
        try Data("original bytes".utf8).write(to: source)
        let attachment = AskAttachment(kind: .file, name: "original.txt", text: "extracted",
                                       localSourcePath: source.path)
        let image = "data:image/jpeg;base64," + Data([0xFF, 0xD8, 0xFF]).base64EncodedString()
        try await store.captureInputs([attachment], image: image, messageId: "message",
                                      owner: "owner", conversationId: "chat")
        let first = store.url(owner: "owner", conversationId: "chat")
        let second = try await store.ensure(owner: "owner", conversationId: "another-chat")
        #expect(first != second)
        let inputs = try FileManager.default.contentsOfDirectory(atPath: first.appendingPathComponent("inputs").path)
        let original = try #require(inputs.first { $0.hasSuffix("original.txt") })
        #expect(try Data(contentsOf: first.appendingPathComponent("inputs/" + original)) == Data("original bytes".utf8))
        #expect(inputs.contains { $0.hasSuffix("-screenshot.jpg") })
        let records = try JSONDecoder().decode([AskConversationWorkspaceStore.FileRecord].self,
            from: Data(contentsOf: first.appendingPathComponent(".typeflux/files.json")))
        #expect(records.count == 2)
        #expect(records.contains { $0.originalPath == source.path })
    }

    @Test func draftSourcePathDoesNotReachTheModelRequest() throws {
        var draft = AskDraft()
        draft.attachments = [AskAttachment(kind: .file, name: "secret.txt", text: "safe",
                                           localSourcePath: "/private/secret.txt")]
        let restored = try JSONDecoder().decode(AskDraft.self, from: JSONEncoder().encode(draft))
        #expect(restored.attachments?.first?.localSourcePath == "/private/secret.txt")
        let request = restored.request(deviceId: "device", tools: [])
        #expect(request.attachments?.first?.localSourcePath == nil)
        #expect(!String(decoding: try JSONEncoder().encode(request), as: UTF8.self).contains("/private/secret.txt"))
    }

    @Test func reopeningWorkspaceKeepsUserFilesAndGeneratedOutputs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-workspace-reopen-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AskConversationWorkspaceStore(rootURL: root)
        let folder = try await store.ensure(owner: "owner", conversationId: "chat")
        let userFile = folder.appendingPathComponent("work/user-notes.txt")
        try Data("keep this".utf8).write(to: userFile)
        let generated = try await store.saveOutput(Data([1, 2, 3]), name: "diagram.png",
                                                   owner: "owner", conversationId: "chat")
        #expect(try await store.ensure(owner: "owner", conversationId: "chat") == folder)
        #expect(try Data(contentsOf: userFile) == Data("keep this".utf8))
        #expect(try Data(contentsOf: generated) == Data([1, 2, 3]))
    }

    @Test func commandStartsInTheProvidedWorkspace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ask-command-workspace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await AskHostCommand().run(command: "pwd", timeout: 5, workingDirectory: directory)
        #expect(!result.isError)
        #expect(result.content.contains(directory.path))
    }
}
