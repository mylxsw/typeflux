import Combine
import SwiftUI

/// Stream deltas update the transcript without rebuilding the composer and sidebar.
/// Durable conversation, approval and input changes still use the model publisher.
@MainActor
final class AskTranscriptStreamUpdates: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
}

struct AskTranscriptStreamContent<Content: View>: View {
    @ObservedObject var updates: AskTranscriptStreamUpdates
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}
