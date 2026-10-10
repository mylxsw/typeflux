import Combine
import Foundation

/// The live viewport width, committed by the same clock that resizes the native panel.
/// A standalone view without a controller uses the model's final size instead.
final class ClipboardPanelLayout: ObservableObject {
    @Published private(set) var width: CGFloat?

    static func boundedWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, ClipboardPanelView.width), ClipboardPanelView.size(showsPreview: true).width)
    }

    func setWidth(_ width: CGFloat) {
        let bounded = Self.boundedWidth(width)
        if self.width != bounded { self.width = bounded }
    }
}
