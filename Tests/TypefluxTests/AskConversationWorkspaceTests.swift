import Foundation
import Testing
@testable import Typeflux

@Suite("Ask conversation workspaces")
struct AskConversationWorkspaceTests {
    @Test func commandDefinitionDescribesBoundAndUnboundWorkspaces() {
        let directory = URL(fileURLWithPath: "/tmp/Typeflux conversation workspace")
        let bound = AskHostCommand.definition(workingDirectory: directory).description
        #expect(bound.contains("Current working directory (conversation workspace): /tmp/Typeflux conversation workspace\n"))
        #expect(bound.contains("New project directory: /tmp/Typeflux conversation workspace/work/\n"))
        #expect(bound.contains("Use TYPEFLUX_WORKSPACE for the absolute workspace path."))
        #expect(bound.contains(AskFileTools.workspaceInstruction))

        let unbound = AskHostCommand.definition.description
        #expect(unbound.contains("No conversation workspace is bound; the command starts in the user's home folder."))
        #expect(!unbound.contains("New project directory:"))
    }

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

    @Test func namesByChatStartAndCreatesOnlyNeededDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AskConversationWorkspaceStore(rootURL: root)
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-20T05:06:07Z"))
        let id = UUID().uuidString
        var chat = AskConversation(id: id, title: "Chat", revision: 1, updatedAt: date.addingTimeInterval(86400),
            messages: [.init(id: "first", role: "user", text: "Hello", createdAt: date)])
        try await store.saveConversation(chat, owner: "owner")
        let folder = store.url(owner: "owner", conversationId: id)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd/HHmmss"
        #expect(folder.path.hasSuffix(formatter.string(from: date) + "-" + id.lowercased()))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [".typeflux"])
        try await store.captureInputs([], image: nil, messageId: "empty", owner: "owner", conversationId: id)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("inputs").path))
        let output = try await store.saveOutput(Data([1]), name: "a.png", owner: "owner", conversationId: id)
        #expect(output.deletingLastPathComponent().lastPathComponent == "outputs")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("work").path))
        chat.updatedAt = Date()
        chat.revision += 1
        try await store.saveConversation(chat, owner: "owner")
        let reopened = AskConversationWorkspaceStore(rootURL: root)
        #expect(try await reopened.ensure(owner: "owner", conversationId: id) == folder)
        let other = try await reopened.ensure(owner: "another-owner", conversationId: id, createdAt: date)
        #expect(other != folder)
    }

    @Test func migratesLegacyWorkspaceAndPreservesNonemptyFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AskConversationWorkspaceStore(rootURL: root)
        let id = UUID().uuidString.lowercased()
        let account = String(AskToolPolicy.digest("owner").dropFirst(7).prefix(16))
        let legacy = root.appendingPathComponent(account).appendingPathComponent(id)
        let secure = try AskSecureDirectory.openRoot(legacy)
        for name in ["inputs", "outputs", "work", ".typeflux"] {
            _ = try secure.child(name, create: true, privateDirectory: true)
        }
        try Data("keep".utf8).write(to: legacy.appendingPathComponent("inputs/original.txt"))
        let date = Date(timeIntervalSince1970: 1700000000)
        let chat = AskConversation(id: id, title: "Old", revision: 1, updatedAt: Date(),
            messages: [.init(id: "first", role: "user", text: "Hello", createdAt: date)])
        try AskCoding.encoder().encode(chat).write(to: legacy.appendingPathComponent(".typeflux/conversation.json"))
        let migrated = try await store.ensure(owner: "owner", conversationId: id)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try Data(contentsOf: migrated.appendingPathComponent("inputs/original.txt")) == Data("keep".utf8))
        #expect(!FileManager.default.fileExists(atPath: migrated.appendingPathComponent("outputs").path))
        #expect(!FileManager.default.fileExists(atPath: migrated.appendingPathComponent("work").path))
        #expect(store.url(owner: "owner", conversationId: id) == migrated)
        try await store.discard(owner: "owner", conversationId: id)
        #expect(!FileManager.default.fileExists(atPath: migrated.path))
    }

    @Test func migrationNeverOverwritesAConflictingDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AskConversationWorkspaceStore(rootURL: root)
        let id = UUID().uuidString.lowercased()
        let date = Date(timeIntervalSince1970: 1700000000)
        let destination = try await store.ensure(owner: "owner", conversationId: id, createdAt: date)
        try Data("new".utf8).write(to: destination.appendingPathComponent("new.txt"))
        let legacy = destination.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(id)
        _ = try AskSecureDirectory.openRoot(legacy)
        try Data("old".utf8).write(to: legacy.appendingPathComponent("old.txt"))
        let reopened = AskConversationWorkspaceStore(rootURL: root)
        await #expect(throws: (any Error).self) {
            try await reopened.ensure(owner: "owner", conversationId: id, createdAt: date)
        }
        #expect(try Data(contentsOf: legacy.appendingPathComponent("old.txt")) == Data("old".utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("new.txt")) == Data("new".utf8))
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
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("work"), withIntermediateDirectories: true)
        let userFile = folder.appendingPathComponent("work/user-notes.txt")
        try Data("keep this".utf8).write(to: userFile)
        let generated = try await store.saveOutput(Data([1, 2, 3]), name: "diagram.png",
                                                   owner: "owner", conversationId: "chat")
        #expect(try await store.ensure(owner: "owner", conversationId: "chat") == folder)
        #expect(try Data(contentsOf: userFile) == Data("keep this".utf8))
        #expect(try Data(contentsOf: generated) == Data([1, 2, 3]))
    }

    @Test func discardingOnlyTheTemporaryWorkspaceCannotFollowLinksOrRecreateIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-workspace-discard-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AskConversationWorkspaceStore(rootURL: root.appendingPathComponent("workspaces"))
        let temporary = try await store.ensure(owner: "owner", conversationId: "temporary")
        let ordinary = try await store.ensure(owner: "owner", conversationId: "ordinary")
        let external = root.appendingPathComponent("external.txt")
        try Data("keep".utf8).write(to: external)
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("work"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: temporary.appendingPathComponent("work/external.txt"),
                                                    withDestinationURL: external)

        try await store.discard(owner: "owner", conversationId: "temporary")
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(FileManager.default.fileExists(atPath: ordinary.path))
        #expect(try Data(contentsOf: external) == Data("keep".utf8))
        await #expect(throws: CancellationError.self) {
            try await store.ensure(owner: "owner", conversationId: "temporary")
        }
    }

    @Test func commandStartsInTheProvidedWorkspace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ask-command-workspace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await AskHostCommand().run(command: "pwd; mktemp", timeout: 5, workingDirectory: directory)
        #expect(!result.isError)
        #expect(result.content.contains(directory.path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".typeflux/tmp").path))
    }
}
