import AppKit

/// Reuses immutable rich text when lazy transcript rows are recreated during navigation.
/// Entries are disposable and bounded so streaming revisions cannot grow without limit.
@MainActor
final class AskTranscriptRenderCache {
    static let shared = AskTranscriptRenderCache()
    private let entries = NSCache<NSString, NSAttributedString>()

    init() {
        entries.countLimit = 128
        entries.totalCostLimit = 8 * 1024 * 1024
    }

    func value(text: String, markdown: Bool, dark: Bool) -> NSAttributedString? {
        entries.object(forKey: key(text: text, markdown: markdown, dark: dark))
    }

    func insert(_ value: NSAttributedString, text: String, markdown: Bool, dark: Bool) {
        // Approximate attribute/storage overhead as well as the retained source key.
        let cost = text.utf16.count * 2 + value.length * 16
        guard cost <= entries.totalCostLimit else { return }
        entries.setObject(NSAttributedString(attributedString: value),
                          forKey: key(text: text, markdown: markdown, dark: dark), cost: cost)
    }

    private func key(text: String, markdown: Bool, dark: Bool) -> NSString {
        "\(markdown ? 1 : 0)\(dark ? 1 : 0):\(text)" as NSString
    }
}
