#if DEBUG
    import Foundation
    import TypefluxChat

    /// Explicit, network-free fixture for screenshots and local UI inspection.
    enum SyntheticPreview {
        static func makeStore() -> ChatStore {
            ChatStore(
                service: PreviewService(showTools: ProcessInfo.processInfo.arguments.contains("--synthetic-tools")),
                credentials: PreviewCredentials(),
                deviceID: "synthetic-device",
                isSynthetic: true
            )
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
        init(showTools: Bool = false) {
            if showTools {
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
            offset == 0 ? [ChatConversationSummary(id: document.id, title: document.title)] : []
        }

        func conversation(id _: String, token _: String) async throws -> ChatConversation {
            document
        }

        func send(conversationId: String, request: ChatSendRequest, token _: String) async throws -> ChatConversation {
            if document.id != conversationId {
                document = ChatConversation(
                    id: conversationId,
                    title: "Synthetic conversation"
                )
            }
            document.messages.append(ChatMessage(
                id: request.id,
                role: "user",
                text: request.text,
                image: request.image
            ))
            document.messages.append(ChatMessage(
                id: UUID().uuidString,
                role: "assistant",
                text: "This is a synthetic preview. Sign in without the preview launch argument to use Typeflux Cloud."
            ))
            document.revision += 1
            return document
        }

        func cancel(conversationId _: String, runId _: String, token _: String) async throws -> ChatConversation {
            document.run?.status = "cancelled"
            document.run?.error = "Response stopped."
            document.revision += 1
            return document
        }

        func observe(
            id _: String,
            token _: String,
            onValue: @concurrent @Sendable (ChatConversation) async throws -> Void
        ) async throws {
            try await onValue(document)
            while document.run?.isActive == true {
                try await Task.sleep(for: .seconds(1))
                try await onValue(document)
            }
        }
    }
#endif
