import AppKit
import TypefluxUI

/// Reference metrics for the remaining legacy layouts; controls draw their own native bezel.
enum SettingsControlMetrics {
    static let height = TypefluxControlHeight.textField.value(for: .classic)
    static let menuHeight = TypefluxControlHeight.popup.value(for: .classic)
    static let fontSize = NSFont.preferredFont(forTextStyle: .body).pointSize
}
