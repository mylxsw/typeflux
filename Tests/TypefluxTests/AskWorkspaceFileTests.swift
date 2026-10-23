import Foundation
import Testing
@testable import Typeflux

@Suite("Ask side panel file listing")
struct AskWorkspaceFileTests {
    private func file(_ path: String, _ origin: AskWorkspaceFile.Origin, message: String? = nil,
                      at seconds: TimeInterval, size: Int64 = 10) -> AskWorkspaceFile {
        AskWorkspaceFile(relativePath: path, size: size, modifiedAt: Date(timeIntervalSince1970: seconds),
                         origin: origin, messageId: message)
    }

    @Test func displayNamesDropTheWorkspacePrefixes() {
        #expect(AskWorkspaceFile.displayName("inputs/0123456789abcdef-fedcba9876543210-report.pdf") == "report.pdf")
        #expect(AskWorkspaceFile.displayName("inputs/0123456789abcdef-screenshot.jpg") == "screenshot.jpg")
        #expect(AskWorkspaceFile.displayName("outputs/1b4e28ba-2fa1-11d2-883f-0016d3cca427-chart.png") == "chart.png")
        // Work files and unprefixed names stay as they are.
        #expect(AskWorkspaceFile.displayName("work/0123456789abcdef-fedcba9876543210-a.py") ==
            "0123456789abcdef-fedcba9876543210-a.py")
        #expect(AskWorkspaceFile.displayName("outputs/plain.html") == "plain.html")
        #expect(AskWorkspaceFile.Origin.folder("inputs") == .upload)
        #expect(AskWorkspaceFile.Origin.folder("outputs") == .generated)
        #expect(AskWorkspaceFile.Origin.folder("work") == .process)
        #expect(AskWorkspaceFile.Origin.folder(".typeflux") == nil)
        let report = file("outputs/Report.HTML", .generated, at: 1)
        #expect(report.id == "outputs/Report.HTML")
        #expect(report.pathExtension == "html")
    }

    @Test func filtersByOriginAndSearchesNamesOnly() {
        let files = [
            file("inputs/0123456789abcdef-fedcba9876543210-Sales.csv", .upload, message: "m1", at: 1),
            file("outputs/report.html", .generated, at: 2),
            file("work/sales/clean.py", .process, at: 3)
        ]
        var query = AskWorkspaceFileQuery()
        #expect(files.filter(query.matches).count == 3)
        query.origin = .process
        #expect(files.filter(query.matches).map(\.relativePath) == ["work/sales/clean.py"])
        query.origin = nil
        query.search = "  SALES "
        // The folder name `sales` does not match; the uploaded file's display name does.
        #expect(files.filter(query.matches).map(\.origin) == [.upload])
        query.search = "0123456789abcdef"
        #expect(files.filter(query.matches).isEmpty)
        #expect(AskWorkspaceFileQuery.counts(files) == [.upload: 1, .generated: 1, .process: 1])
    }

    @Test func sortsNewestFirstAndBreaksTiesByName() {
        let sorted = AskWorkspaceFileQuery.sorted([
            file("outputs/b.txt", .generated, at: 5),
            file("outputs/a10.txt", .generated, at: 5),
            file("outputs/a2.txt", .generated, at: 5),
            file("outputs/new.txt", .generated, at: 9),
            file("work/a2.txt", .process, at: 5)
        ])
        #expect(sorted.map(\.relativePath) == [
            "outputs/new.txt", "outputs/a2.txt", "work/a2.txt", "outputs/a10.txt", "outputs/b.txt"
        ])
    }

    @Test func groupsFollowTheConversationNewestMessageFirst() {
        let files = [
            file("inputs/a.txt", .upload, message: "m1", at: 30),
            file("inputs/b.txt", .upload, message: "m2", at: 10),
            file("inputs/c.txt", .upload, message: "m2", at: 20),
            file("inputs/d.txt", .upload, message: "ghost-old", at: 5),
            file("inputs/e.txt", .upload, message: "ghost-new", at: 50),
            file("outputs/f.txt", .generated, at: 40)
        ]
        let groups = AskWorkspaceFileQuery().groups(files, messageOrder: ["m1", "m2"])
        #expect(groups.map(\.messageId) == ["m2", "m1", "ghost-new", "ghost-old", nil])
        #expect(groups[0].files.map(\.relativePath) == ["inputs/c.txt", "inputs/b.txt"])
        #expect(groups.last?.id == "")
        #expect(groups.first?.id == "m2")
        // Without a known order, groups follow their newest file.
        let byDate = AskWorkspaceFileQuery().groups(files)
        #expect(byDate.map(\.messageId) == ["ghost-new", "m1", "m2", "ghost-old", nil])
        var query = AskWorkspaceFileQuery()
        query.origin = .generated
        #expect(query.groups(files).map(\.messageId) == [nil])
        query.search = "missing"
        #expect(query.groups(files).isEmpty)
    }

    @Test func listsWorkspaceFilesWithTheirMessagesAndSkipsLinks() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("side-panel-list-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = AskConversationWorkspaceStore(rootURL: base.appendingPathComponent("workspaces"))
        #expect(try await store.listFiles(owner: "owner", conversationId: "chat").isEmpty)

        let source = base.appendingPathComponent("notes.md")
        try Data("# Notes".utf8).write(to: source)
        try await store.captureInputs([AskAttachment(kind: .file, name: "notes.md", text: "x", localSourcePath: source.path)],
                                      image: nil, messageId: "m1", owner: "owner", conversationId: "chat")
        _ = try await store.saveOutput(Data("<p>hi</p>".utf8), name: "page.html", owner: "owner", conversationId: "chat")
        let root = store.url(owner: "owner", conversationId: "chat")
        let work = root.appendingPathComponent("work/step", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("print(1)".utf8).write(to: work.appendingPathComponent("run.py"))
        try Data("x".utf8).write(to: work.appendingPathComponent(".DS_Store"))
        let outside = base.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("link.txt"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("work/linked-dir"),
                                                   withDestinationURL: base)

        let files = try await store.listFiles(owner: "owner", conversationId: "chat")
        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["notes.md", "page.html", "run.py"])
        #expect(byName["notes.md"]?.origin == .upload)
        #expect(byName["notes.md"]?.messageId == "m1")
        #expect(byName["notes.md"]?.size == 7)
        #expect(byName["page.html"]?.origin == .generated)
        #expect(byName["page.html"]?.messageId == nil)
        #expect(byName["run.py"]?.relativePath == "work/step/run.py")
        #expect(byName["run.py"]?.origin == .process)
        #expect(files.allSatisfy { $0.modifiedAt > Date(timeIntervalSince1970: 0) })
    }

    @Test func linkedWorkspaceFoldersAreNotListed() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("side-panel-link-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = AskConversationWorkspaceStore(rootURL: base.appendingPathComponent("workspaces"))
        let root = try await store.ensure(owner: "owner", conversationId: "chat")
        let elsewhere = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: elsewhere.appendingPathComponent("leak.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outputs"), withDestinationURL: elsewhere)
        #expect(try await store.listFiles(owner: "owner", conversationId: "chat").isEmpty)
    }

    @Test func addedFilesBecomeUploadsWithoutAMessage() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("side-panel-add-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = AskConversationWorkspaceStore(rootURL: base.appendingPathComponent("workspaces"))
        let first = base.appendingPathComponent("data.csv"), second = base.appendingPathComponent("data copy.csv")
        try Data("a,b\n1,2\n".utf8).write(to: first)
        try Data("c".utf8).write(to: second)
        let added = try await store.addFiles([first, second, first], owner: "owner", conversationId: "chat")
        #expect(added.count == 3)
        #expect(Set(added).count == 3, "Adding the same file twice keeps both copies")
        let files = try await store.listFiles(owner: "owner", conversationId: "chat")
        #expect(files.map(\.name).sorted() == ["data copy.csv", "data.csv", "data.csv"])
        #expect(files.allSatisfy { $0.origin == .upload && $0.messageId == nil })
        let root = store.url(owner: "owner", conversationId: "chat")
        let records = try JSONDecoder().decode([AskConversationWorkspaceStore.FileRecord].self,
                                               from: Data(contentsOf: root.appendingPathComponent(".typeflux/files.json")))
        #expect(records.filter { $0.source == "user_added" }.count == 3)
        #expect(records.contains { $0.originalPath == first.path && $0.byteSize == 8 })

        await #expect(throws: (any Error).self) {
            try await store.addFiles([base], owner: "owner", conversationId: "chat")
        }
        await #expect(throws: (any Error).self) {
            try await store.addFiles([base.appendingPathComponent("missing.txt")], owner: "owner", conversationId: "chat")
        }
    }
}
