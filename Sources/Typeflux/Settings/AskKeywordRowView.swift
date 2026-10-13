import SwiftUI

/// Function and description share one flexible column; keywords wrap underneath.
/// This keeps long aliases readable even in a narrow settings pane.
struct AskKeywordRowView: View {
    let row: AskKeywordListRow
    let toggle: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.kind.symbol).font(.body).foregroundStyle(row.kind.tint).accessibilityHidden(true)
            Button(action: open) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.name).font(.body)
                        .foregroundStyle(TypefluxColor.label.color)
                    Text(row.summary).font(.subheadline)
                        .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if row.keyword.isEmpty {
                        Text(L("ask.system.setKeyword")).font(.subheadline)
                            .foregroundStyle(TypefluxColor.accent.color)
                    } else {
                        Text(row.source.allKeywords.joined(separator: " · ")).font(.body.monospaced())
                            .foregroundStyle(.secondary)
                            .help(L("ask.settings.keywords.defaultKeyword") + ": " + row.keyword)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ask.settings.keywords.edit." + row.keyword)
            Toggle("", isOn: Binding(get: { row.enabled }, set: { _ in toggle() }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).padding(.top, 2)
                .disabled(row.keyword.isEmpty)
                .accessibilityLabel(L("ask.settings.keywords.enabled") + " " + row.keyword)
        }
        .opacity(row.enabled ? 1 : 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.settings.keywords.row." + row.keyword)
    }
}
