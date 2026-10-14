import AppKit
import SwiftUI

/// Full selection details without adding a row to the launcher itself.
struct AskSelectionHoverCard: View {
    let item: AskContextItem
    let text: String

    static let width: CGFloat = 360
    static let inset: CGFloat = 16
    static let maximumTextHeight: CGFloat = 220

    private var included: Bool {
        item.style == .active
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("ask.selection")).font(.headline)
                Spacer()
                Text(L(included ? "ask.context.selection.enabled" : "ask.context.selection.disabled"))
                    .font(.subheadline)
                    .foregroundStyle(included ? AskTheme.accent : StudioTheme.textSecondary)
                    .accessibilityIdentifier("ask.context.selection.status")
            }
            Text([item.sourceAppName, L("ask.context.selection.characters", text.count)]
                .compactMap(\.self).joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(StudioTheme.textSecondary)
            Divider()
            ScrollView(.vertical) {
                Text(verbatim: text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ask.context.selection.hoverText")
            }
            .frame(height: Self.textHeight(text))
            .accessibilityIdentifier("ask.context.selection.hoverPreview")
            Text(L(included ? "ask.context.selection.disableHint" : "ask.context.selection.enableHint"))
                .font(.subheadline)
                .foregroundStyle(StudioTheme.textSecondary)
        }
        .foregroundStyle(StudioTheme.textPrimary)
        .padding(Self.inset)
        .frame(width: Self.width)
        .accessibilityIdentifier("ask.context.selection.details")
    }

    /// Short excerpts fit naturally; long selections remain fully scrollable.
    static func textHeight(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let bounds = NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: NSSize(width: width - inset * 2, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return min(maximumTextHeight, max(ceil(font.ascender - font.descender + font.leading), ceil(bounds.height) + 4))
    }
}
