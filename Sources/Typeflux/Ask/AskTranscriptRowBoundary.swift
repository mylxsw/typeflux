import SwiftUI

/// Compare inexpensive row inputs before constructing its full SwiftUI hierarchy.
/// Completed rows retain their expansion, selection and hover state during streaming.
struct AskTranscriptRowRenderKey: Equatable {
    var model: ObjectIdentifier
    var revision: UInt64
    var item: AskTranscriptItem
    var phase: AskRunPhase?
    var latestActivityID: String?
    var lastContentID: String?
    var regenerable: String?
    var approval: AskToolCall?
    var notesEnabled: Bool
    var savedToNotes: Bool
    var highlightedID: String?
}

struct AskTranscriptRowBoundary<Key: Equatable, Content: View>: View, Equatable {
    var key: Key
    @ViewBuilder var content: () -> Content
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    var body: some View { content() }
}
