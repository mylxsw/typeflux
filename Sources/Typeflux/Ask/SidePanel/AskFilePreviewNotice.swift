import SwiftUI

/// Keeps technical diagnostics available without letting them dominate the preview.
struct AskFilePreviewNotice: View {
    let message: String
    @State var isExpanded = false

    static func details(_ message: String) -> [String] {
        var seen = Set<String>()
        return message.components(separatedBy: .newlines).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && seen.insert(value).inserted ? value : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(TFColors.warning).accessibilityHidden(true)
                Text(L("ask.sidePanel.file.previewIssue"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(TFColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TFButton(title: L(isExpanded ? "ask.sidePanel.file.hideDetails" : "ask.sidePanel.file.details"),
                         systemImage: isExpanded ? "chevron.up" : "chevron.down", kind: .plain,
                         size: .small) { isExpanded.toggle() }
                    .accessibilityValue(L(isExpanded ? "component.expanded" : "component.collapsed"))
            }
            if isExpanded {
                ScrollView {
                    Text(Self.details(message).joined(separator: "\n"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(TFColors.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 72)
            }
        }
        .padding(10)
        .background(TFColors.warning.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: TFMetrics.fieldCornerRadius))
        .accessibilityIdentifier("ask.sidePanel.file.previewIssue")
    }
}
