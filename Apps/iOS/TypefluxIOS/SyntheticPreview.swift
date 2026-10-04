// swiftlint:disable file_length
// Debug-only fixtures stay together so release builds cannot include a preview transport.
#if DEBUG
    import Foundation
    import TypefluxChat
    import UIKit

    /// Explicit, network-free fixture for screenshots and local UI inspection.
    enum SyntheticPreview {
        enum Scenario: String, CaseIterable, Sendable {
            case tools, rich, stream, failure, empty, history

            static func resolve(_ arguments: [String]) -> Scenario? {
                allCases.first { arguments.contains("--synthetic-" + $0.rawValue) }
            }
        }

        static func makeStore(arguments: [String] = ProcessInfo.processInfo.arguments,
                              now: Date = Date(), streamInterval: Duration? = nil) -> ChatStore {
            ChatStore(service: makeService(arguments: arguments, now: now, streamInterval: streamInterval),
                      credentials: PreviewCredentials(), deviceID: "synthetic-device", isSynthetic: true)
        }

        static func makeService(arguments: [String] = [], now: Date = Date(),
                                streamInterval: Duration? = nil) -> any ChatAPI {
            let scenario = Scenario.resolve(arguments)
            let interval = streamInterval ?? (arguments.contains("--synthetic-stream-slow") ? .seconds(6) : .seconds(3))
            let documents: [ChatConversation]?
            switch scenario {
            case .rich:
                let photo = photoData()
                exportPhotoFixture(photo)
                documents = [richDocument(photo: photo)]
            case .stream: documents = [streamDocument()]
            case .failure: documents = [failureDocument()]
            case .empty: documents = []
            case .history: documents = historyDocuments(now: now)
            case .tools, nil: documents = nil
            }
            return PreviewService(scenario: scenario, documents: documents, streamInterval: interval)
        }

        nonisolated static let streamChunks = [
            "先把今天最重要的一件事写下来。",
            streamAnswer
        ]
        nonisolated static let streamAnswer = """
        ## 给今天留一点余地

        1. 写下今天最重要的一件事。
        2. 留出 **25 分钟**，先做一个可以交付的小结果。
        3. 完成后停一下，再决定是否继续。

        > 计划的作用，是帮你开始，而不是把每一分钟填满。

        ### 把目标写成一个动作

        不写“把项目做好”，改成“把接口的一条正常调用跑通”。动作越具体，越容易判断自己是否已经完成。

        ### 留出不被打断的时间

        先关闭不相关的页面，把当前需要的信息放在手边。遇到新的想法可以记下来，等这一小步结束后再处理。

        ### 用结果调整计划

        完成之后记录哪里顺利、哪里需要帮助。计划允许修改，已经完成的小结果会告诉你下一步应该放在哪里。

        ### 为明天留下入口

        写下一个可以直接开始的动作，让下次打开项目时，不必重新猜测今天做到了哪里。

        最后，为下一步留下一个清楚的小动作。

        这是纯离线演示回答，没有发送任何网络请求。
        """
    }

    private extension SyntheticPreview {
        static func streamDocument() -> ChatConversation {
            ChatConversation(id: "preview-stream", title: "慢一点，也能把事情做好", revision: 1, messages: [
                ChatMessage(id: "stream-intro-question", role: "user", text: "我想给一天安排一个轻一点的开始。"),
                ChatMessage(id: "stream-intro-answer", role: "assistant", text: """
                可以先说说你今天最想完成什么。

                这是离线流式演示：发送一条消息后，可以观察思考、逐步生成、完成和停止状态。
                """)
            ])
        }

        static func failureDocument() -> ChatConversation {
            ChatConversation(id: "preview-failure", title: "回答中断后，保留已经写下的内容", revision: 4, messages: [
                ChatMessage(id: "failure-question", role: "user", text: "帮我比较本地缓存和云端同步的取舍。"),
                ChatMessage(id: "failure-answer", role: "assistant", text: """
                            可以先明确两条边界：**本地缓存保证离线可读，云端负责跨设备同步**。

                            - 本地保存最近使用的会话。
                            - 恢复网络后，以服务端版本为准。

                            下面继续分析冲突处理……
                            """, reasoning: "先区分可用性和一致性的职责，再讨论失败恢复。", reasoningMilliseconds: 1800,
                            isError: true)
            ], run: ChatRun(id: "failure-run", deviceId: "synthetic-device", status: "failed",
                            error: "演示错误：连接已中断。已生成的内容仍然保留，你可以继续发送消息。"))
        }

        static func richDocument(photo: Data) -> ChatConversation {
            let search = ChatToolCall(id: "rich-search", function: .init(name: "web_search",
                                                                         arguments: #"{"query":"离线优先应用的同步设计"}"#))
            let files = ChatToolCall(
                id: "rich-files",
                function: .init(name: "files",
                                arguments: #"{"action":"read","path":"设计笔记/同步方案.md"}"#)
            )
            return ChatConversation(id: "preview-rich", title: "把跨设备同步方案讲清楚", revision: 8, messages: [
                ChatMessage(id: "rich-question", role: "user", text: """
                我们要做一个支持离线阅读的聊天客户端。请先查阅资料，再比较三种同步方案，给出能落地的建议。
                说明正常路径、网络中断和多端冲突；最后给我一小段 Swift 示例。
                """),
                ChatMessage(id: "rich-tool-call", role: "assistant", text: "我会先看资料，再核对已有设计笔记。",
                            reasoning: "需要把会话版本、消息身份和断线恢复分开，避免为了视觉上的实时感重复发送消息。",
                            reasoningMilliseconds: 3200, toolCalls: [search, files]),
                ChatMessage(id: "rich-search-result", role: "tool", text: "演示搜索结果：离线读取、版本快照、幂等请求。",
                            toolCallId: search.id),
                ChatMessage(id: "rich-files-result", role: "tool", text: "演示设计笔记：服务端持有版本号；客户端缓存最近会话。",
                            toolCallId: files.id),
                ChatMessage(id: "rich-answer", role: "assistant", text: richAnswer,
                            reasoning: "先采用单一服务端版本和明确的请求身份；等到确实需要多端同时编辑，再增加冲突合并。",
                            reasoningMilliseconds: 4800),
                ChatMessage(id: "rich-image-question", role: "user", text: "这张方案草图里，哪些部分还需要补充？",
                            attachments: [ChatAttachment(kind: "image", id: "rich-photo", name: "同步方案草图.jpg",
                                                         image: "data:image/jpeg;base64," + photo
                                                             .base64EncodedString())]),
                ChatMessage(id: "rich-image-answer", role: "assistant", text: """
                草图已经把 **输入、同步和展示** 分开了。建议再补三处：

                - 在同步层标记请求 ID 和会话版本。
                - 在本地缓存旁边画出清理策略。
                - 给网络中断增加一条恢复路径。

                图片由测试绘图代码生成，不包含真实用户资料。
                """),
                ChatMessage(id: "rich-followup", role: "user", text: "那我们第一版先做哪些？"),
                ChatMessage(id: "rich-followup-answer", role: "assistant", text: """
                第一版只需要三件事：**缓存最近会话、断线后重新拉取快照、重复请求保持同一个 ID**。

                先验证“断网时能读、恢复后不重复”，再扩展复杂的冲突合并。

                _本会话是纯离线测试数据，没有调用搜索、文件或模型服务。_
                """)
            ], run: ChatRun(id: "rich-run", deviceId: "synthetic-mac", status: "completed"))
        }

        static let richAnswer = """
        ## 推荐：快照同步，先把恢复做可靠

        第一版采用 **本地缓存 + 服务端会话版本**。读取可以离线完成；发送消息需要服务端确认。

        ### 三种方案怎么选

        | 方案 | 离线阅读 | 冲突处理 | 实施成本 | 适用场景 |
        | :--- | :---: | --- | --- | --- |
        | 全量快照 | 支持 | 以服务端版本为准 | 较低 | 会话记录、结果查看 |
        | 增量事件 | 支持 | 处理事件顺序与缺口 | 中等 | 长会话与频繁更新 |
        | 多端合并 | 支持 | 字段级合并与冲突提示 | 较高 | 多人同时编辑同一内容 |

        ### 第一版的调用顺序

        1. 打开会话，先展示最近一次缓存。
        2. 拉取服务端快照，只有版本更新才替换。
        3. 发送时保留请求身份，避免恢复后重复提交。
           - 明确失败：允许修改后重新发送。
           - 结果未知：先查询，再决定是否重试。

        > 展示旧内容和重复执行操作，承担的是两种不同风险。

        ```swift
        struct ConversationSnapshot {
            let revision: Int64
            let messages: [String]
        }

        func accept(_ next: ConversationSnapshot, current: ConversationSnapshot) -> ConversationSnapshot {
            next.revision > current.revision ? next : current
        }
        ```

        ---

        **验证重点**：断网、切换账号、切换会话，以及发送成功但回执丢失。
        本段用于检查中文排版、长代码横向滚动和宽表格，所有数据均为离线演示。
        """

        static func historyDocuments(now: Date) -> [ChatConversation] {
            let titles = ["把今天最重要的一件事写下来", "用三句话介绍一个新想法", "周末读书清单", "产品评审前的准备",
                          "如何写出更容易理解的接口文档", "让错误提示更有帮助", "整理这周的项目进展", "设计一个离线阅读流程",
                          "一次网络中断的复盘", "给未来的自己留一份笔记", "理解并发任务的取消", "从一个小实验开始", "一个月前的灵感"]
            let dayOffsets = [0, 0, 1, 1, 2, 3, 4, 6, 8, 12, 16, 24, 40]
            return titles.enumerated().map { index, title in
                let date = now.addingTimeInterval(-Double(dayOffsets[index] * 86400 + index * 60))
                return ChatConversation(
                    id: "history-\(index + 1)",
                    title: title,
                    revision: 1,
                    updatedAt: date,
                    messages: [
                        ChatMessage(id: "history-question-\(index + 1)", role: "user", text: title, createdAt: date),
                        ChatMessage(id: "history-answer-\(index + 1)", role: "assistant",
                                    text: "先把问题缩小到一个可以完成的步骤，再用结果决定下一步。\n\n这是第 \(index + 1) 条离线历史演示。",
                                    createdAt: date)
                    ]
                )
            }
        }
    }

    extension SyntheticPreview {
        /// Generated test media, also exported for PhotosPicker integration checks.
        static func photoData() -> Data {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1; format.opaque = true
            let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 540), format: format)
                .image { context in
                    UIColor(red: 0.95, green: 0.95, blue: 0.92, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 900, height: 540))
                    let title = "跨设备同步 · 方案草图" as NSString
                    title.draw(at: CGPoint(x: 48, y: 40), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: UIColor.darkGray
                    ])
                    for (index, label) in ["用户输入", "同步与缓存", "会话展示"].enumerated() {
                        let rect = CGRect(x: 48 + index * 282, y: 175, width: 238, height: 150)
                        UIColor(red: 0.84, green: 0.90, blue: 0.98, alpha: 1).setFill()
                        UIBezierPath(roundedRect: rect, cornerRadius: 18).fill()
                        (label as NSString).draw(at: CGPoint(x: rect.minX + 40, y: rect.minY + 57), withAttributes: [
                            .font: UIFont.systemFont(ofSize: 27, weight: .medium), .foregroundColor: UIColor.darkGray
                        ])
                    }
                    ("SYNTHETIC · 本地生成的测试图片" as NSString).draw(at: CGPoint(x: 48, y: 445), withAttributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 21, weight: .regular), .foregroundColor: UIColor.gray
                    ])
                }
            return image.jpegData(compressionQuality: 0.85) ?? Data()
        }

        private static func exportPhotoFixture(_ data: Data) {
            guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
            try? data.write(to: cache.appendingPathComponent("synthetic-photo.jpg"), options: .atomic)
        }
    }

    @MainActor
    private final class PreviewCredentials: CredentialStore {
        var value: SavedAccount? = SavedAccount(
            email: "preview@example.invalid",
            session: ChatSession(accessToken: "synthetic", expiresAt: 0, refreshToken: nil)
        )
        func load() throws -> SavedAccount? {
            value
        }

        func save(_ account: SavedAccount) throws {
            value = account
        }

        func clear() throws {
            value = nil
        }
    }

    private actor PreviewService: ChatAPI {
        var document = ChatConversation(id: "preview", title: "A quieter start to the day", revision: 1, messages: [
            ChatMessage(
                id: "question",
                role: "user",
                text: "Help me make a simple morning routine that leaves room to think."
            ),
            ChatMessage(id: "answer", role: "assistant", text: """
                        Start with **three small things**:

                        1. Leave your phone aside for the first ten minutes.
                        2. Write down the one thing that matters today.
                        3. Make a cup of coffee and give yourself a little quiet.

                        A good routine should create space, not another list to complete.

                        | Habit | Time | Why |
                        | --- | --- | --- |
                        | Quiet | 10 min | Make room to think |
                        | Plan | 2 min | Pick one priority |

                        ```swift
                        let priority = "One meaningful thing"
                        ```
                        """, reasoning: "Keep the routine short enough to repeat, with time for a single priority.",
                        reasoningMilliseconds: 2400)
        ])
        private var documents: [ChatConversation] = []
        private let scenario: SyntheticPreview.Scenario?
        private let streamInterval: Duration
        private var streamSequence = 0
        private var streamSteps: [String: Int] = [:]

        init(scenario: SyntheticPreview.Scenario?, documents: [ChatConversation]?, streamInterval: Duration) {
            self.scenario = scenario
            self.streamInterval = streamInterval
            if scenario == .tools {
                let tool = ChatToolCall(
                    id: "preview-tool",
                    function: .init(name: "read_file", arguments: "{\"path\":\"notes.txt\"}")
                )
                document = ChatConversation(id: "preview-tools", title: "A task from your Mac", revision: 1, messages: [
                    ChatMessage(id: "tool-question", role: "user", text: "Read my notes."),
                    ChatMessage(id: "tool-call", role: "assistant", text: "", toolCalls: [tool]),
                    ChatMessage(
                        id: "tool-result",
                        role: "tool",
                        text: "Permission was denied on the Mac.",
                        toolCallId: tool.id,
                        isError: true
                    )
                ], run: ChatRun(id: "preview-run", deviceId: "synthetic-mac", status: "waiting_tool",
                                preview: "Waiting for access to the notes.", pending: [tool]))
            }
            if let documents {
                self.documents = documents
            } else {
                self.documents = [document]
            }
        }

        func login(email _: String, password: String) async throws -> ChatSession {
            if password == "invalid" {
                throw ChatAPIError.server(
                    code: "INVALID_CREDENTIALS",
                    message: "Synthetic sign-in failed."
                )
            }
            return ChatSession(accessToken: "synthetic", expiresAt: 0, refreshToken: nil)
        }

        func refresh(refreshToken _: String) async throws -> ChatSession {
            throw ChatAPIError.unauthorized
        }

        func logout(refreshToken _: String) async throws {}
        func models(token _: String) async throws -> [ChatModel] {
            [ChatModel(id: "preview", name: "Preview model", vision: true,
                       pricing: ["multiplier": "3"], reasoning: true,
                       reasoningEfforts: ["low", "medium", "high", "xhigh", "max"],
                       contextWindowTokens: 1_000_000, maxOutputTokens: 64000),
             ChatModel(id: "text-preview", name: "Text preview model", vision: false,
                       reasoning: true, reasoningEfforts: ["low", "medium", "high"]),
             ChatModel(id: "fast-preview", name: "Fast preview model", vision: true,
                       pricing: ["multiplier": "1"], reasoning: true,
                       reasoningEfforts: ["low", "medium", "high"],
                       contextWindowTokens: 128_000, maxOutputTokens: 32000),
             ChatModel(id: "standard-preview", name: "Standard preview model", vision: false, reasoning: false)]
        }

        func list(token _: String, offset: Int) async throws -> [ChatConversationSummary] {
            let pageSize = scenario == .history ? 5 : documents.count
            return documents.dropFirst(max(0, offset)).prefix(pageSize).map {
                ChatConversationSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt)
            }
        }

        func conversation(id: String, token _: String) async throws -> ChatConversation {
            try documents[documentIndex(id)]
        }

        func send(conversationId: String, request: ChatSendRequest, token _: String) async throws -> ChatConversation {
            if !documents.contains(where: { $0.id == conversationId }) {
                documents.insert(ChatConversation(id: conversationId, title: "Synthetic conversation"), at: 0)
            }
            let index = try documentIndex(conversationId)
            documents[index].messages.append(ChatMessage(
                id: request.id,
                role: "user",
                text: request.text,
                image: request.image
            ))
            if scenario == .stream {
                streamSequence += 1
                let runID = "synthetic-stream-\(streamSequence)"
                streamSteps[runID] = 0
                documents[index].run = ChatRun(id: runID, deviceId: "synthetic-device", status: "running",
                                               reasoning: "先理解今天的目标，再把建议收敛到几个能立即开始的小步骤。")
            } else {
                documents[index].messages.append(ChatMessage(id: UUID().uuidString, role: "assistant", text:
                    "This is a synthetic preview. Sign in without the preview launch argument to use Typeflux Cloud."))
                documents[index].run = nil
            }
            documents[index].revision += 1
            return documents[index]
        }

        func cancel(conversationId: String, runId _: String, token _: String) async throws -> ChatConversation {
            let index = try documentIndex(conversationId)
            documents[index].run?.status = "cancelled"
            documents[index].run?.error = "Response stopped."
            documents[index].revision += 1
            return documents[index]
        }

        func observe(id: String, token _: String,
                     onValue: @concurrent @Sendable (ChatConversation) async throws -> Void) async throws {
            try await onValue(documents[documentIndex(id)])
            while try documents[documentIndex(id)].run?.isActive == true {
                try await Task.sleep(for: streamInterval)
                try Task.checkCancellation()
                let index = try documentIndex(id)
                guard documents[index].run?.isActive == true else { break }
                if scenario == .stream {
                    advanceStream(index: index)
                }
                try await onValue(documents[index])
            }
        }

        private func advanceStream(index: Int) {
            guard let runID = documents[index].run?.id else { return }
            let step = streamSteps[runID, default: 0]
            if step < SyntheticPreview.streamChunks.count {
                documents[index].run?.preview = SyntheticPreview.streamChunks[step]
                documents[index].run?.reasoningMilliseconds = 2100
            } else {
                documents[index].messages.append(ChatMessage(
                    id: "stream-answer-" + runID.replacingOccurrences(of: "synthetic-stream-", with: ""),
                    role: "assistant", text: SyntheticPreview.streamAnswer,
                    reasoning: documents[index].run?.reasoning, reasoningMilliseconds: 2100
                ))
                documents[index].run?.status = "completed"
                documents[index].run?.preview = nil
            }
            streamSteps[runID] = step + 1
            documents[index].revision += 1
        }

        private func documentIndex(_ id: String) throws -> Int {
            guard let index = documents.firstIndex(where: { $0.id == id }) else {
                throw ChatAPIError.server(code: "NOT_FOUND", message: "Synthetic conversation not found.")
            }
            return index
        }
    }
#endif
