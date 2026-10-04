#if DEBUG
    import Foundation
    import Testing
    import TypefluxChat
    @testable import TypefluxIOS
    import UIKit

    @MainActor
    struct SyntheticPreviewTests {
        @Test func `launch arguments select only explicit known scenarios`() {
            #expect(SyntheticPreview.Scenario.resolve([]) == nil)
            #expect(SyntheticPreview.Scenario.resolve(["--synthetic-preview", "--unknown"]) == nil)
            #expect(SyntheticPreview.Scenario.resolve(["--synthetic-rich"]) == .rich)
            #expect(SyntheticPreview.Scenario.resolve(["--synthetic-stream", "--synthetic-stream-slow"]) == .stream)
            #expect(SyntheticPreview.Scenario.resolve(["--synthetic-rich", "--synthetic-tools"]) == .tools)
        }

        @Test func `existing default and desktop fixtures retain their identifiers and behavior`() async throws {
            let standard = SyntheticPreview.makeService()
            let first = try await standard.conversation(id: "preview", token: "synthetic")
            #expect(first.messages.map(\.id) == ["question", "answer"])
            let tools = SyntheticPreview.makeService(arguments: ["--synthetic-tools"])
            let desktop = try await tools.conversation(id: "preview-tools", token: "synthetic")
            #expect(desktop.run?.requiresDesktop == true)
            #expect(desktop.messages.last?.isError == true)
            let cancelled = try await tools.cancel(conversationId: desktop.id, runId: "preview-run", token: "synthetic")
            #expect(cancelled.run?.status == "cancelled")
            #expect(cancelled.run?.error == "Response stopped.")
        }

        @Test func `rich fixture contains matched tools readable markdown and decodable generated photo`() async throws {
            let service = SyntheticPreview.makeService(arguments: ["--synthetic-rich"])
            let document = try await service.conversation(id: "preview-rich", token: "synthetic")
            #expect(document.messages.filter { $0.role == "user" }.count == 3)
            let calls = document.messages.flatMap { $0.toolCalls ?? [] }
            #expect(calls.map(\.id) == ["rich-search", "rich-files"])
            #expect(calls.allSatisfy { call in document.messages.contains { $0.toolCallId == call.id } })
            let answer = try #require(document.messages.first { $0.id == "rich-answer" })
            let blocks = ChatMarkdown.parse(answer.text)
            #expect(blocks.contains {
                if case .table = $0 {
                    true
                } else {
                    false
                }
            })
            #expect(blocks.contains {
                if case .code = $0 {
                    true
                } else {
                    false
                }
            })
            #expect(answer.reasoningMilliseconds == 4800)
            let photoMessage = try #require(document.messages.first { $0.id == "rich-image-question" })
            #expect(photoMessage.image == nil)
            let encoded = try #require(photoMessage.imageDataURLs.first)
            let image = try #require(ImageAttachment.decode(encoded))
            #expect(image.size == CGSize(width: 900, height: 540))
            #expect(document.run?.status == "completed")
            let cache = try #require(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
            let exported = try Data(contentsOf: cache.appendingPathComponent("synthetic-photo.jpg"))
            #expect(UIImage(data: exported)?.size == image.size)
        }

        @Test func `empty history accepts first message and preserves the photo in its snapshot`() async {
            let store = SyntheticPreview.makeStore(arguments: ["--synthetic-empty"])
            await store.restore()
            #expect(store.isSynthetic)
            #expect(store.conversations.isEmpty)
            #expect(!store.hasMore)
            store.draft = "看看这张草图。"
            let dataURL = "data:image/jpeg;base64," + SyntheticPreview.photoData().base64EncodedString()
            store.imageDataURL = dataURL
            await store.send()
            #expect(store.conversation?.messages.first?.image == dataURL)
            #expect(store.conversation?.messages.count == 2)
            #expect(store.conversations.count == 1)
            #expect(store.imageDataURL == nil)
            #expect(store.draft.isEmpty)
            await store.signOut()
        }

        @Test func `history paginates without duplicates and each row opens its own document`() async {
            let now = Date(timeIntervalSince1970: 1_791_108_000)
            let store = SyntheticPreview.makeStore(arguments: ["--synthetic-history"], now: now)
            await store.restore()
            #expect(store.conversations.count == 5)
            #expect(store.conversations.first?.updatedAt == now)
            await store.loadMore()
            #expect(store.conversations.count == 10)
            await store.loadMore()
            #expect(store.conversations.count == 13)
            #expect(Set(store.conversations.map(\.id)).count == 13)
            await store.loadMore()
            #expect(!store.hasMore)
            await store.select("history-13")
            #expect(store.conversation?.messages.first?.id == "history-question-13")
            #expect(store.conversation?.title == "一个月前的灵感")
            await store.signOut()
        }

        @Test func `failed answer remains readable and a follow up clears the old run error`() async {
            let store = SyntheticPreview.makeStore(arguments: ["--synthetic-failure"])
            await store.restore()
            await store.select("preview-failure")
            #expect(!store.isRunning)
            #expect(store.conversation?.run?.error?.contains("连接已中断") == true)
            #expect(store.conversation?.messages.last?.isError == true)
            store.draft = "先说最简单的方案。"
            #expect(store.canSend)
            await store.send()
            #expect(store.conversation?.messages.count == 4)
            #expect(store.conversation?.run == nil)
            await store.signOut()
        }

        @Test func `sending streams successive revisions then commits exactly one completed answer`() async throws {
            let service = SyntheticPreview.makeService(arguments: ["--synthetic-stream"], streamInterval: .zero)
            let sent = try await service.send(
                conversationId: "preview-stream",
                request: request("first"),
                token: "synthetic"
            )
            #expect(sent.run?.id == "synthetic-stream-1")
            #expect(sent.run?.isActive == true)
            #expect(sent.messages.last?.role == "user")
            let recorder = PreviewSnapshotRecorder()
            try await service.observe(id: "preview-stream", token: "synthetic") { await recorder.append($0) }
            let snapshots = await recorder.values
            #expect(snapshots.map(\.revision) == [2, 3, 4, 5])
            #expect(snapshots.compactMap { $0.run?.preview } == SyntheticPreview.streamChunks)
            #expect(snapshots.last?.run?.status == "completed")
            #expect(snapshots.last?.run?.preview == nil)
            #expect(snapshots.last?.messages.filter { $0.id == "stream-answer-1" }.count == 1)
            #expect(snapshots.last?.messages.last?.text == SyntheticPreview.streamAnswer)
            let next = try await service.send(
                conversationId: "preview-stream",
                request: request("second"),
                token: "synthetic"
            )
            #expect(next.run?.id == "synthetic-stream-2")
            #expect(next.messages.contains { $0.id == "stream-answer-1" })
            _ = try await service.cancel(
                conversationId: "preview-stream",
                runId: "synthetic-stream-2",
                token: "synthetic"
            )
        }

        @Test func `cancelling a stream preserves partial text without appending a completed answer`() async throws {
            let service = SyntheticPreview.makeService(arguments: ["--synthetic-stream"], streamInterval: .zero)
            _ = try await service.send(conversationId: "preview-stream", request: request("stop"), token: "synthetic")
            try await service.observe(id: "preview-stream", token: "synthetic") { snapshot in
                if snapshot.run?.preview != nil {
                    _ = try await service.cancel(
                        conversationId: snapshot.id,
                        runId: "synthetic-stream-1",
                        token: "synthetic"
                    )
                }
            }
            let stopped = try await service.conversation(id: "preview-stream", token: "synthetic")
            #expect(stopped.run?.status == "cancelled")
            #expect(stopped.run?.preview == SyntheticPreview.streamChunks.first)
            #expect(!stopped.messages.contains { $0.id == "stream-answer-1" })
        }

        @Test func `unknown fixture identifiers fail instead of returning unrelated private state`() async {
            let service = SyntheticPreview.makeService(arguments: ["--synthetic-rich"])
            await #expect(throws: ChatAPIError.self) {
                try await service.conversation(id: "missing", token: "synthetic")
            }
        }

        private func request(_ id: String) -> ChatSendRequest {
            ChatSendRequest(id: id, deviceId: "synthetic-device", text: "给我一个简单的开始。")
        }
    }

    private actor PreviewSnapshotRecorder {
        var values: [ChatConversation] = []
        func append(_ value: ChatConversation) {
            values.append(value)
        }
    }
#endif
