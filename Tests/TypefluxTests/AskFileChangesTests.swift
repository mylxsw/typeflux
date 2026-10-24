import Foundation
import Testing
@testable import Typeflux

/// "Files changed this round": workspace snapshots, their comparison, and how the changes are
/// recorded in `.typeflux/files.json`.
@Suite("Ask file changes per round")
struct AskFileChangesTests {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("file-changes-" + UUID().uuidString)
        for folder in ["inputs", "outputs", "work"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder),
                                                    withIntermediateDirectories: true)
        }
        return root
    }

    private func write(_ text: String, _ path: String, in root: URL, modified: Date? = nil) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    private func entry(_ size: Int64, _ seconds: TimeInterval, _ digest: String?) -> AskWorkspaceSnapshot.Entry {
        .init(size: size, modifiedAt: Date(timeIntervalSince1970: seconds), digest: digest)
    }

    private func call(_ name: String, _ arguments: String) -> AskToolCall {
        AskToolCall(id: UUID().uuidString, function: .init(name: name, arguments: arguments))
    }

    // MARK: Snapshots

    @Test func capturesOutputsAndWorkWithoutUploadsHiddenFilesOrLinks() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("chart", "outputs/chart.html", in: root)
        try write("print(1)", "work/scripts/clean.py", in: root)
        try write("upload", "inputs/data.csv", in: root)
        try write("secret", "work/.cache", in: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outputs/link.txt"),
                                                   withDestinationURL: root.appendingPathComponent("inputs/data.csv"))
        let snapshot = AskWorkspaceSnapshot.capture(root: root)
        #expect(Set(snapshot.entries.keys) == ["outputs/chart.html", "work/scripts/clean.py"])
        let chart = try #require(snapshot.entries["outputs/chart.html"])
        #expect(chart.size == 5)
        #expect(chart.digest == AskToolPolicy.digest(Data("chart".utf8)))
        // A workspace the run has not created yet is empty, as is a linked folder.
        #expect(AskWorkspaceSnapshot.capture(root: root.appendingPathComponent("missing")).entries.isEmpty)
    }

    @Test func linkedFoldersAreNotScanned() throws {
        let root = try workspace(), outside = try workspace()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try write("x", "outputs/elsewhere.txt", in: outside)
        try FileManager.default.removeItem(at: root.appendingPathComponent("outputs"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outputs"),
                                                   withDestinationURL: outside.appendingPathComponent("outputs"))
        #expect(AskWorkspaceSnapshot.capture(root: root).entries.isEmpty)
    }

    @Test func unchangedFilesReuseTheirDigest() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        try write("same", "outputs/a.txt", in: root, modified: time)
        try write("fresh", "outputs/b.txt", in: root, modified: time)
        var previous = AskWorkspaceSnapshot()
        previous.entries["outputs/a.txt"] = .init(size: 4, modifiedAt: time, digest: "kept")
        previous.entries["outputs/b.txt"] = .init(size: 99, modifiedAt: time, digest: "stale")
        let snapshot = AskWorkspaceSnapshot.capture(root: root, reusing: previous)
        #expect(snapshot.entries["outputs/a.txt"]?.digest == "kept", "Same size and time: not read again")
        #expect(snapshot.entries["outputs/b.txt"]?.digest == AskToolPolicy.digest(Data("fresh".utf8)))
    }

    @Test func comparisonListsAddedAndModifiedButNotDeletedFiles() {
        var before = AskWorkspaceSnapshot()
        before.entries = [
            "outputs/kept.md": entry(3, 1, "a"),
            "outputs/grown.md": entry(3, 1, "b"),
            "outputs/edited.md": entry(3, 1, "c"),
            "outputs/touched.md": entry(3, 1, "d"),
            "work/gone.py": entry(3, 1, "e"),
            "work/big.bin": entry(3, 1, nil),
            "work/big-same.bin": entry(3, 1, nil)
        ]
        var after = AskWorkspaceSnapshot()
        after.entries = [
            "outputs/kept.md": entry(3, 1, "a"),
            "outputs/grown.md": entry(4, 2, "b2"),
            "outputs/edited.md": entry(3, 2, "c2"),
            // Only the time changed; the content is the same.
            "outputs/touched.md": entry(3, 5, "d"),
            // Too large to hash: a new time counts as a change, the same time does not.
            "work/big.bin": entry(3, 2, nil),
            "work/big-same.bin": entry(3, 1, nil),
            "work/new.py": entry(1, 2, "f")
        ]
        let changes = before.changes(to: after)
        #expect(changes.map(\.path) == ["outputs/edited.md", "outputs/grown.md", "work/big.bin", "work/new.py"])
        #expect(changes.map(\.kind) == [.modified, .modified, .modified, .added])
        #expect(AskWorkspaceSnapshot().changes(to: AskWorkspaceSnapshot()).isEmpty)
    }

    @Test func aRealRoundReportsWritesAndIgnoresTouchesAndDeletes() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try write("v1", "outputs/report.md", in: root, modified: old)
        try write("same", "work/notes.txt", in: root, modified: old)
        try write("bye", "work/tmp.txt", in: root, modified: old)
        let before = AskWorkspaceSnapshot.capture(root: root)
        try write("v2 longer", "outputs/report.md", in: root)
        try write("same", "work/notes.txt", in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("work/tmp.txt"))
        try write("<p>new</p>", "outputs/chart.html", in: root)
        let changes = before.changes(to: AskWorkspaceSnapshot.capture(root: root, reusing: before))
        #expect(changes == [.init(path: "outputs/chart.html", kind: .added),
                            .init(path: "outputs/report.md", kind: .modified)])
    }

    // MARK: Tool summaries

    @Test func modifiedFilesAreDescribedByTheRunsFileTool() {
        let root = "/ws/chat"
        let calls = [
            call("files", #"{"action":"edit","path":"outputs/a.md"}"#),
            call("files", #"{"action":"edit","path":"./outputs/a.md"}"#),
            call("files", #"{"action":"write","path":"/ws/chat/work/b.py"}"#),
            call("files", #"{"action":"read","path":"outputs/a.md"}"#),
            call("files", #"{"action":"write","path":"/elsewhere/c.txt"}"#),
            call("files", #"{"action":"write","path":"../escape.txt"}"#),
            call("files", "not json"),
            call("run_code", #"{"action":"write","path":"outputs/a.md"}"#)
        ]
        let counts = AskWorkspaceFileChange.toolCounts(calls, root: root)
        #expect(counts.count == 2)
        #expect(counts["outputs/a.md"]?.edits == 2)
        #expect(counts["outputs/a.md"]?.writes == 0)
        #expect(counts["work/b.py"]?.writes == 1)
        #expect(AskWorkspaceFileChange.workspacePath("/ws/chat/", root: root) == nil)
        #expect(AskWorkspaceFileChange.workspacePath("  outputs//x.md ", root: root + "/") == "outputs/x.md")
        #expect(AskWorkspaceFileChange(path: "work/a.py", kind: .added).isProcess)
        #expect(!AskWorkspaceFileChange(path: "outputs/work/a.py", kind: .added).isProcess)
        #expect(AskWorkspaceFileChange(path: "outputs/1b4e28ba-2fa1-11d2-883f-0016d3cca427-chart.png", kind: .added).name
            == "chart.png")
    }

    // MARK: Recording in files.json

    @Test func changesAreRecordedWithTheAnswerAndReadBack() async throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = AskConversationWorkspaceStore(rootURL: base.appendingPathComponent("workspaces"))
        let root = try await store.ensure(owner: "owner", conversationId: "chat")
        try write("chart", "outputs/chart.html", in: root)
        try write("v2", "work/clean.py", in: root)
        try await store.recordChanges([], messageId: "a1", owner: "owner", conversationId: "chat")
        #expect(store.listChanges(owner: "owner", conversationId: "chat").isEmpty, "Nothing to record")
        try await store.recordChanges([.init(path: "work/clean.py", kind: .modified, edits: 3),
                                       .init(path: "outputs/chart.html", kind: .added)],
                                      messageId: "a1", owner: "owner", conversationId: "chat")
        try await store.recordChanges([.init(path: "outputs/chart.html", kind: .modified, writes: 1)],
                                      messageId: "a2", owner: "owner", conversationId: "chat")
        let changes = store.listChanges(owner: "owner", conversationId: "chat")
        #expect(changes["a1"] == [.init(path: "outputs/chart.html", kind: .added),
                                  .init(path: "work/clean.py", kind: .modified, edits: 3)])
        #expect(changes["a2"] == [.init(path: "outputs/chart.html", kind: .modified, writes: 1)])
        // The Files tab groups a file under the first message it was recorded with.
        let files = try await store.listFiles(owner: "owner", conversationId: "chat")
        #expect(files.first { $0.relativePath == "outputs/chart.html" }?.messageId == "a1")
        #expect(store.listChanges(owner: "owner", conversationId: "other").isEmpty)
    }

    @Test func olderRecordsWithoutAChangeStillRead() async throws {
        // Written before change tracking: no `change`, `writes` or `edits` keys.
        let legacy = #"""
        [{"byteSize":5,"messageId":"m1","originalPath":"/Users/me/a.csv","path":"inputs/x-y-a.csv","source":"user_original"},
         {"byteSize":9,"path":"outputs/u-report.html","source":"generated"},
         {"path":"outputs/u-report.html","source":"run_change","messageId":"a1","change":"added"},
         {"path":"work/z.py","source":"run_change","messageId":"a1","change":"renamed"}]
        """#
        let changes = AskConversationWorkspaceStore.changes(in: Data(legacy.utf8))
        #expect(changes == ["a1": [.init(path: "outputs/u-report.html", kind: .added)]],
                "Uploads and saved outputs are not changes; unknown kinds are skipped")
        #expect(AskConversationWorkspaceStore.changes(in: Data("{broken".utf8)).isEmpty)
        let records = try JSONDecoder().decode([AskConversationWorkspaceStore.FileRecord].self, from: Data(legacy.utf8))
        #expect(records[0].change == nil && records[0].writes == nil && records[0].edits == nil)

        // Appending to an older file keeps its records and writes no empty keys.
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = AskConversationWorkspaceStore(rootURL: base.appendingPathComponent("workspaces"))
        let root = try await store.ensure(owner: "owner", conversationId: "chat")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".typeflux"),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent(".typeflux/files.json")
        try Data(#"[{"messageId":"m1","path":"inputs/x-y-a.csv","source":"user_original"}]"#.utf8).write(to: file)
        try await store.recordChanges([.init(path: "outputs/r.md", kind: .added)], messageId: "a1",
                                      owner: "owner", conversationId: "chat")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(#""path":"inputs\/x-y-a.csv""#))
        #expect(!text.contains("writes") && !text.contains("edits"))
        #expect(store.listChanges(owner: "owner", conversationId: "chat")["a1"]?.map(\.path) == ["outputs/r.md"])
    }

    @Test func sentFilesKeepTheNameTheirInputsCopyUses() async throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Q3 sales.csv")
        try Data("a,b".utf8).write(to: source)
        let attachment = AskAttachment(id: "att", kind: .file, name: "Q3 sales.csv", text: "a,b",
                                       localSourcePath: source.path)
        let store = AskConversationWorkspaceStore(rootURL: base.appendingPathComponent("workspaces"))
        try await store.captureInputs([attachment], image: nil, messageId: "m1", owner: "owner", conversationId: "chat")
        let path = try #require(AskConversationWorkspaceStore.inputPath(attachment, messageId: "m1"))
        let root = store.url(owner: "owner", conversationId: "chat")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        #expect(AskWorkspaceFile.displayName(path) == "Q3 sales.csv")
        let folder = AskAttachment(id: "dir", kind: .folder, name: "Project", path: "/tmp/project")
        #expect(AskConversationWorkspaceStore.inputPath(folder, messageId: "m1") == nil)
    }

    // MARK: Rounds

    @Test func aRoundsChangesBelongToItsLastAnswer() {
        func message(_ id: String, _ role: String, steered: Bool? = nil, calls: [AskToolCall]? = nil) -> AskMessage {
            AskMessage(id: id, role: role, text: id, toolCalls: calls, createdAt: Date(), steered: steered)
        }
        let edit = call("files", #"{"action":"edit","path":"outputs/a.md"}"#)
        let older = call("files", #"{"action":"write","path":"outputs/old.md"}"#)
        let conversation = AskConversation(id: "c", title: "", revision: 1, updatedAt: Date(), messages: [
            message("u1", "user"), message("s0", "assistant", calls: [older]), message("a0", "assistant"),
            message("u2", "user"), message("s1", "assistant", calls: [edit]), message("t1", "tool"),
            message("u3", "user", steered: true), message("a2", "assistant")
        ])
        let round = AskConversationModel.fileChangeRound(conversation)
        #expect(round?.answerId == "a2")
        #expect(round?.calls == [edit])
        // A round that ended on a step (cancelled) still records with that step.
        var stopped = conversation
        stopped.messages.removeLast()
        #expect(AskConversationModel.fileChangeRound(stopped)?.answerId == "s1")
        stopped.messages = [message("u1", "user")]
        #expect(AskConversationModel.fileChangeRound(stopped) == nil, "No answer, nothing to record with")

        let annotated = AskConversationModel.annotated([.init(path: "outputs/a.md", kind: .modified),
                                                        .init(path: "outputs/b.md", kind: .added)],
                                                       calls: [edit], root: "/ws")
        #expect(annotated.map(\.edits) == [1, 0])
        let merged = AskConversationModel.merged([.init(path: "b", kind: .added), .init(path: "a", kind: .added)],
                                                 [.init(path: "b", kind: .modified)])
        #expect(merged == [.init(path: "a", kind: .added), .init(path: "b", kind: .modified)])
    }

    // MARK: The block's list

    @Test func theListFoldsWorkFilesAndCountsArtifactsAsAdded() throws {
        let html = AskArtifactRef(id: "11111111-aaaa", ownerId: "o", conversationId: "c", runId: "r", version: "v",
                                  mediaType: "text/html", sizeBytes: 10, sha256: "s", cleanup: "device_30_days")
        var image = html
        image.id = "22222222-bbbb"
        image.mediaType = "image/png"
        let outputs = AskRunOutputs(storedArtifacts: [html, image], storedArtifactNames: [html.id: "index.html"])
        let artifacts = AskFileChangeList.artifacts(outputs)
        #expect(artifacts.map(\.name) == ["index.html"], "Images stay inline as pictures")
        let list = AskFileChangeList(changes: [.init(path: "outputs/a.md", kind: .modified),
                                               .init(path: "work/b.py", kind: .added),
                                               .init(path: "work/c.py", kind: .modified)],
                                     artifacts: artifacts)
        #expect(list.main.map(\.path) == ["outputs/a.md"])
        #expect(list.process.map(\.path) == ["work/b.py", "work/c.py"])
        #expect(list.added == 2 && list.modified == 2)
        #expect(!list.isEmpty)
        #expect(AskFileChangeList(changes: []).isEmpty)
    }

    // MARK: Links

    @Test func linksFollowTheSettingAndCommandClickLeavesForTheBrowser() throws {
        let page = try #require(URL(string: "https://example.com/a"))
        #expect(AskLinkRouter.route(page, external: false, opening: .sidePanel, panelAvailable: true) == .sidePanel(page))
        #expect(AskLinkRouter.route(page, external: true, opening: .sidePanel, panelAvailable: true) == .browser(page))
        #expect(AskLinkRouter.route(page, external: false, opening: .browser, panelAvailable: true) == .browser(page))
        #expect(AskLinkRouter.route(page, external: false, opening: .sidePanel, panelAvailable: false) == .browser(page),
                "Without the in-app browser a page still opens")
        let mail = try #require(URL(string: "mailto:a@example.com"))
        #expect(AskLinkRouter.route(mail, external: false, opening: .sidePanel, panelAvailable: true) == .browser(mail))
        let file = try #require(AskLinkRouter.link(forDestination: "./outputs/Q3 report.html"))
        #expect(file.scheme == AskLinkRouter.fileScheme)
        #expect(AskLinkRouter.route(file, external: true, opening: .browser, panelAvailable: false)
            == .workspaceFile("outputs/Q3 report.html"), "A workspace file always opens in the panel")
        let bogus = try #require(URL(string: "typeflux-file:../etc/passwd"))
        #expect(AskLinkRouter.route(bogus, external: false, opening: .sidePanel, panelAvailable: true) == .browser(bogus))
    }

    @Test func onlyWorkspaceFoldersBecomeFileLinks() {
        #expect(AskLinkRouter.workspacePath("work/analyze.py") == "work/analyze.py")
        #expect(AskLinkRouter.workspacePath("outputs/%E6%8A%A5%E5%91%8A.md") == "outputs/报告.md")
        #expect(AskLinkRouter.workspacePath("inputs/./a.csv") == "inputs/a.csv")
        for path in ["outputs", "outputs/", "notes.md", "/Users/me/outputs/a.md", "outputs/../../a",
                     "work\\a.py", ".typeflux/files.json", "https://example.com"] {
            #expect(AskLinkRouter.workspacePath(path) == nil, "\(path)")
            #expect(AskLinkRouter.link(forDestination: path) == nil, "\(path)")
        }
        #expect(AskLinkRouter.workspacePath(fromLink: URL(string: "https://example.com/outputs/a")!) == nil)
    }

    @Test func theLinkSettingDefaultsToTheSidePanelAndPersists() throws {
        let suite = "AskFileChangesTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.askLinkOpening == .sidePanel)
        settings.askLinkOpening = .browser
        #expect(SettingsStore(defaults: defaults).askLinkOpening == .browser)
        defaults.set("bogus", forKey: "ask.links.opening")
        #expect(settings.askLinkOpening == .sidePanel)
    }

    @Test func aPageAlreadyOpenIsTheSamePage() throws {
        let page = try #require(URL(string: "https://example.com"))
        #expect(AskSidePanel.samePage(URL(string: "https://example.com/"), page))
        #expect(AskSidePanel.samePage(URL(string: "https://example.com#"), page))
        #expect(AskSidePanel.samePage(page, try #require(URL(string: "https://example.com/"))))
        #expect(!AskSidePanel.samePage(URL(string: "https://example.com/a"), page))
        #expect(!AskSidePanel.samePage(URL(string: "https://example.com/a"), try #require(URL(string: "https://example.com/a/"))),
                "Only an empty path ignores its slash")
        #expect(!AskSidePanel.samePage(nil, page))
    }
}
