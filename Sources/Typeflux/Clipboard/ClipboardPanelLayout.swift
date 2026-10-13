import Combine
import Foundation

/// The live viewport width, committed by the same clock that resizes the native panel.
/// A standalone view without a controller uses the model's final size instead.
final class ClipboardPanelLayout: ObservableObject {
    @Published private(set) var width: CGFloat?

    static func boundedWidth(_ width: CGFloat, style: InterfaceStyle = .liquidGlass) -> CGFloat {
        min(max(width, ClipboardPanelView.width(for: style)),
            ClipboardPanelView.size(showsPreview: true, style: style).width)
    }

    func setWidth(_ width: CGFloat, style: InterfaceStyle = .liquidGlass) {
        let bounded = Self.boundedWidth(width, style: style)
        if self.width != bounded { self.width = bounded }
    }
}
