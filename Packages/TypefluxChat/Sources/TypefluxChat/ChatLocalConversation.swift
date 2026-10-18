import Foundation

/// Builds and updates conversations answered on this device by the user's own
/// provider. They use the same document shape as cloud conversations so the
/// transcript renders them identically.
public enum ChatLocalConversation {
    public static func system(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withFullDate]
        return "You are Typeflux, a helpful assistant running in the Typeflux iPhone app. "
            + "Reply in the language the user writes in, and use Markdown when it helps. "
            + "You have no tools and cannot browse the web. Today is \(formatter.string(from: now))."
    }

    /// The title a new conversation takes from its first message.
    public static func title(for text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
    }

    /// The turns sent to the provider: user and completed assistant messages.
    public static func providerMessages(_ conversation: ChatConversation) -> [ChatProviderMessage] {
        conversation.messages.compactMap { message in
            guard message.role == "user" || message.role == "assistant", message.isError != true,
                  !message.text.isEmpty || message.hasImage else { return nil }
            return ChatProviderMessage(role: message.role, text: message.text,
                                       image: message.role == "user" ? message.imageDataURLs.first : nil)
        }
    }

    /// Appends the user's message and a running run that will hold the streamed answer.
    public static func begin(_ conversation: ChatConversation?, id: String, text: String, image: String?,
                             modelRef: String, deviceID: String, now: Date = Date()) -> ChatConversation {
        var value = conversation ?? ChatConversation(id: id, title: title(for: text), revision: 0, updatedAt: now)
        if value.title.isEmpty {
            value.title = title(for: text)
        }
        value.messages.append(ChatMessage(id: UUID().uuidString.lowercased(), role: "user", text: text,
                                          createdAt: now, image: image))
        return running(value, modelRef: modelRef, deviceID: deviceID, now: now)
    }

    /// Removes the latest answer so it can be written again.
    public static func regenerate(_ conversation: ChatConversation, messageID: String, modelRef: String,
                                  deviceID: String, now: Date = Date()) -> ChatConversation? {
        guard let index = conversation.messages.lastIndex(where: { $0.id == messageID }),
              conversation.messages[index].role == "assistant" else { return nil }
        var value = conversation
        value.messages.remove(at: index)
        return running(value, modelRef: modelRef, deviceID: deviceID, now: now)
    }

    /// Starts a new run on the conversation as it is, e.g. to retry a failed answer.
    public static func running(_ conversation: ChatConversation, modelRef: String, deviceID: String,
                               now: Date = Date()) -> ChatConversation {
        var value = conversation
        value.revision += 1
        value.updatedAt = now
        value.run = ChatRun(id: UUID().uuidString.lowercased(), deviceId: deviceID, status: "running",
                            updatedAt: now, modelRef: modelRef)
        return value
    }

    /// Shows streamed output in the run preview, as the cloud does.
    public static func progress(_ conversation: ChatConversation, text: String, reasoning: String,
                                started: Date, now: Date = Date()) -> ChatConversation {
        var value = conversation
        value.run?.preview = text.isEmpty ? nil : text
        value.run?.reasoning = reasoning.isEmpty ? nil : reasoning
        value.run?.reasoningMilliseconds = reasoning.isEmpty ? nil : Int(now.timeIntervalSince(started) * 1000)
        value.run?.updatedAt = now
        return value
    }

    /// Ends the run: a completed or stopped answer becomes a message; a failure
    /// keeps the run so the transcript can offer to try again.
    public static func finish(_ conversation: ChatConversation, status: String, text: String, reasoning: String,
                              reasoningMilliseconds: Int?, error: String? = nil,
                              now: Date = Date()) -> ChatConversation {
        var value = conversation
        let modelRef = value.run?.modelRef
        if !text.isEmpty || !reasoning.isEmpty {
            value.messages.append(ChatMessage(id: UUID().uuidString.lowercased(), role: "assistant", text: text,
                                              createdAt: now, reasoning: reasoning.isEmpty ? nil : reasoning,
                                              reasoningMilliseconds: reasoning.isEmpty ? nil : reasoningMilliseconds,
                                              modelRef: modelRef))
        }
        value.revision += 1
        value.updatedAt = now
        value.run?.status = status
        value.run?.preview = nil
        value.run?.reasoning = nil
        value.run?.reasoningMilliseconds = nil
        value.run?.error = error
        value.run?.updatedAt = now
        return value
    }
}
