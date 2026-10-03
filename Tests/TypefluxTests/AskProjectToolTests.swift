import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Project tool approval and integration", .serialized)
@MainActor
struct AskProjectToolTests {
    @MainActor struct Fixture {
        let base: URL
        let root: URL
        let settings: SettingsStore
        let tools: AskLocalTools
        let store: AskProjectWorkspace
        init(enabled: Bool = true) throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            root = base.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("hello\n".utf8).write(to: root.appendingPathComponent("file.txt"))
            settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
            settings.askFileAccessFolders = [root.path]
            store = AskProjectWorkspace(storageURL: base.appendingPathComponent("store"))
            tools = AskLocalTools(
                registry: MCPRegistry(settingsStore: .init(defaults: UserDefaults(suiteName: UUID().uuidString)!)),
                settings: settings,
                projects: store,
                projectModeEnabled: enabled
            )
            tools.bindExecution(ownerId: "owner", conversationId: "conversation", runId: "run")
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: base)
        }

        func call(_ args: [String: Any]) throws -> AskToolCall {
            try .init(id: UUID().uuidString, function: .init(name: "project_files", arguments:
                String(
                    decoding: JSONSerialization.data(withJSONObject: args, options: .sortedKeys),
                    as: UTF8.self
                )))
        }

        func execute(_ args: [String: Any]) async throws -> AskLocalToolOutput {
            let call = try call(args)
            let binding = try await tools.approvalBinding(for: call, conversationId: "conversation")
            #expect(!binding.allowsReuse)
            #expect(!AskToolPolicy.mayReuse(call))
            return try await tools.executeApproved(
                call,
                conversationId: "conversation",
                binding: binding,
                authorize: {}
            )
        }

        func open() async throws -> AskWorkspaceRef {
            let output = try await execute(["action": "open", "root": root.path])
            return try #require(JSONDecoder()
                .decode([String: AskWorkspaceRef].self, from: Data(output.content.utf8))["workspace"])
        }
    }

    @Test func `rollout disabled and unapproved dispatch denied`() async throws {
        let fixture = try Fixture(enabled: false)
        defer { fixture.cleanup() }
        let defs = await fixture.tools.definitions(conversationId: "conversation")
        #expect(!defs.contains { $0.name == "project_files" })
        #expect(defs.contains { $0.name == "files" })
        let call = try fixture.call(["action": "open", "root": fixture.root.path])
        await #expect(throws: (any Error).self) { try await fixture.tools.approvalBinding(
            for: call,
            conversationId: "conversation"
        ) }
        await #expect(throws: (any Error).self) { try await fixture.tools.execute(call, conversationId: "conversation")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.store.storageURL.path))
    }

    @Test func `open edit review export and revert through approval`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let defs = await fixture.tools.definitions(conversationId: "conversation")
        #expect(defs.contains { $0.name == "project_files" })
        var ref = try await fixture.open()
        let read = try await fixture.execute(["action": "read", "workspace_id": ref.id, "path": "file.txt"])
        let page = try JSONDecoder().decode(AskProjectRead.self, from: Data(read.content.utf8))
        let editArgs: [String: Any] = ["action": "edit", "workspace_id": ref.id, "path": "file.txt",
                                       "old_text": "hello", "new_text": "world", "expected_version": page.version]
        #expect(try AskApprovalPresentation.preview(fixture.call(editArgs)) == .diff(removed: "hello", added: "world"))
        #expect(try AskApprovalPresentation.detail(fixture.call(editArgs)) == "file.txt")
        let changed = try await fixture.execute(editArgs)
        ref = try #require(JSONDecoder()
            .decode([String: AskWorkspaceRef].self, from: Data(changed.content.utf8))["workspace"])
        #expect(changed.outcome?.status == "ok")
        let stale = try await fixture.execute(editArgs)
        #expect(stale.isError && stale.outcome?.status == "invalid")
        for action in ["review", "export"] {
            let result = try await fixture.execute(["action": action, "workspace_id": ref.id])
            let review = try #require(AskProjectReview.decode(result.content))
            #expect(review.patch.contains("+world"))
            let data = try fixture.tools.exportProjectPatch(ref, ownerId: "owner", conversationId: "conversation")
            #expect(AskToolPolicy.digest(data) == review.patchHash)
            #expect(review.workspace == ref)
        }
        let listing = try await fixture.execute(["action": "list", "workspace_id": ref.id])
        #expect(listing.content.contains("file.txt"))
        let reverted = try await fixture.execute([
            "action": "revert",
            "workspace_id": ref.id,
            "expected_version": ref.version
        ])
        #expect(!reverted.isError)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("file.txt")) == "hello\n")
        for args: [String: Any] in [
            ["action": "write", "workspace_id": ref.id, "path": "file.txt"],
            ["action": "read", "workspace_id": ref.id], ["action": "revert", "workspace_id": ref.id],
            ["action": "unknown", "workspace_id": ref.id]
        ] {
            #expect(try await fixture.execute(args).isError)
        }
    }

    @Test func `revocation and scope changes between approval and dispatch`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let ref = try await fixture.open()
        let call = try fixture.call(["action": "read", "workspace_id": ref.id, "path": "file.txt"])
        let binding = try await fixture.tools.approvalBinding(for: call, conversationId: "conversation")
        await #expect(throws: (any Error).self) {
            try await fixture.tools.executeApproved(call, conversationId: "conversation", binding: binding) {
                fixture.settings.askFileAccessFolders = []
            }
        }
        #expect(throws: (any Error).self) { try fixture.tools.exportProjectPatch(
            ref,
            ownerId: "owner",
            conversationId: "conversation"
        ) }
        fixture.settings.askFileAccessFolders = [fixture.root.path]
        for (owner, run) in [("other", "run"), ("owner", "other")] {
            fixture.tools.bindExecution(ownerId: owner, conversationId: "conversation", runId: run)
            await #expect(throws: (any Error).self) { try await fixture.tools.approvalBinding(
                for: call,
                conversationId: "conversation"
            ) }
        }
        #expect(throws: (any Error).self) { try fixture.tools.exportProjectPatch(
            ref,
            ownerId: "other",
            conversationId: "conversation"
        ) }
        fixture.tools.bindExecution(ownerId: "owner", conversationId: "conversation", runId: "run")
        await #expect(throws: (any Error).self) {
            try await fixture.tools.executeApproved(call, conversationId: "conversation", binding: binding) {
                try Data("changed by user".utf8).write(
                    to: fixture.root.appendingPathComponent("file.txt"),
                    options: .atomic
                )
            }
        }
        let disabled = AskLocalTools(
            registry: fixture.tools.registry,
            settings: fixture.settings,
            projects: fixture.store
        )
        #expect(try disabled.exportProjectPatch(ref, ownerId: "owner", conversationId: "conversation") == Data())
    }

    @Test func `project review renders and can export fixture screenshots`() throws {
        _ = NSApplication.shared
        let state = AskProjectChangeSet(
            workspace: .init(id: "fixture", ownerId: "owner", conversationId: "conversation",
                             runId: "run", version: "v1", cleanup: "user_managed"),
            root: "/fixture",
            rootIdentity: "1",
            entries: [
                .init(
                    path: "Sources/Welcome.swift",
                    sourceVersion: "v0",
                    original: Data("Hello\n".utf8),
                    updated: Data("Welcome\n".utf8)
                )
            ]
        )
        let review = AskProjectReview(changeSet: state)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = NSHostingView(rootView: AskProjectReviewView(
                review: review,
                exportPatch: { _ in Data(state.patch.utf8) }
            )
            .padding(20).frame(width: 700).background(StudioTheme.surface))
            view.appearance = NSAppearance(named: appearance)
            view.frame.size = view.fittingSize
            view.layoutSubtreeIfNeeded()
            #expect(view.frame.height > 100)
            if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] {
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data
                    .write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("project-review-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
    }
}
