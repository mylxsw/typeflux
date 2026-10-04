import Foundation

/// Applies cloud snapshots/progress while rejecting stale revisions. It deliberately
/// projects only the mobile fields; desktop retains its richer recovery merger.
public struct ChatConversationStreamState: Sendable {
    public private(set) var value: ChatConversation?
    public init() {}

    public mutating func consume(event: String, data: String) throws -> ChatConversation? {
        if event == "unavailable" { throw ChatAPIError.unavailable }
        if event == "snapshot" {
            let next = try ChatCoding.decoder().decode(ChatConversation.self, from: Data(data.utf8))
            if let value, value.id == next.id, next.revision <= value.revision { return nil }
            value = next
            return next
        }
        if event == "progress", var next = value {
            struct Progress: Decodable {
                @ChatConversationID var id: String
                var revision: Int64
                var updatedAt: Date
                var run: ChatRun?
            }
            let progress = try ChatCoding.decoder().decode(Progress.self, from: Data(data.utf8))
            guard progress.id == next.id, progress.revision > next.revision else { return nil }
            next.revision = progress.revision; next.updatedAt = progress.updatedAt; next.run = progress.run
            value = next
            return next
        }
        return nil
    }
}
