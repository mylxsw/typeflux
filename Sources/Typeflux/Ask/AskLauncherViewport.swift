import SwiftUI

/// The launcher card's visible height while its height animates.
///
/// The panel never resizes once per frame: it grows to a new height at once and
/// shrinks only when the motion lands, while the card reveals or hides its
/// results inside it. Only the results' clip observes this value, so a frame of
/// the motion lays out one frame modifier instead of evaluating the whole
/// composer and resizing the native window.
@MainActor
final class AskLauncherViewport: ObservableObject {
    /// The card's visible height, its gutters included; nil until a panel drives it,
    /// in which case the results keep their natural height.
    @Published private(set) var height: CGFloat?

    func show(_ height: CGFloat?) {
        guard self.height != height else { return }
        self.height = height
    }

    /// The results area's height inside a card of the visible height.
    /// - Parameters:
    ///   - chrome: Everything else the card shows, gutters included.
    ///   - available: The hosting view's height, gutters included, used while no
    ///     panel drives the card (before the first presentation, or in a plain host).
    ///   - natural: The results' own height when neither is known.
    func resultsHeight(chrome: CGFloat, available: CGFloat? = nil, natural: CGFloat) -> CGFloat {
        (height ?? available).map { max(0, $0 - chrome) } ?? natural
    }
}

/// Clips the launcher's results to the card's visible height. As a modifier it
/// re-renders without evaluating the results it clips.
struct AskLauncherViewportClip: ViewModifier {
    @ObservedObject var viewport: AskLauncherViewport
    var chrome: CGFloat
    var available: CGFloat?
    var natural: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(height: viewport.resultsHeight(chrome: chrome, available: available, natural: natural),
                   alignment: .top)
            .clipped()
    }
}
