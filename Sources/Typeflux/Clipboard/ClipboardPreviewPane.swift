import SwiftUI

/// The clipboard panel's side pane: the selected entry's full text or a large preview, then
/// its details. Rows stay one size; this is where an entry is seen in full.
struct ClipboardPreviewPane: View {
    static let width: CGFloat = 280

    let entry: ClipboardEntry?
    let isMissing: Bool
    @State private var info: ClipboardMediaInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let entry {
                preview(for: entry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                details(for: entry)
            } else {
                Spacer()
            }
        }
        .padding(14)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .task(id: entry?.id) {
            info = nil
            guard let entry else { return }
            info = await ClipboardMediaInfoProvider.shared.loadInfo(for: entry)
        }
    }

    @ViewBuilder
    private func preview(for entry: ClipboardEntry) -> some View {
        if isMissing {
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                ClipboardEntryPreview(entry: entry, isMissing: true)
            }
        } else if entry.kind.isTextual {
            ScrollView {
                Text(Self.previewText(entry.text ?? entry.title))
                    .font(entry.kind == .code ? .system(size: 12, design: .monospaced) : .system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if entry.hasInlineMedia {
            ClipboardInlineMedia(entry: entry, info: info, isExpanded: true, isMissing: false)
        } else if entry.kind == .pdf {
            VStack(alignment: .leading, spacing: 10) {
                ClipboardThumbnailView(
                    url: entry.fileURLs.first, maxPixelSize: 520, placeholder: "doc", contentMode: .fit
                )
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(entry.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
            }
        } else {
            ScrollView {
                ClipboardEntryPreview(entry: entry, isMissing: false)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func details(for entry: ClipboardEntry) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(Self.detailRows(for: entry, info: info), id: \.label) { row in
                GridRow {
                    Text(row.label).foregroundStyle(StudioTheme.textSecondary.opacity(0.75))
                    Text(row.value)
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(row.label == L("clipboard.preview.location") ? 3 : 1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .font(.system(size: 11.5))
    }

    struct DetailRow: Equatable {
        let label: String
        let value: String
    }

    /// Label/value pairs under the preview: kind, source app, copy time, size and location.
    static func detailRows(for entry: ClipboardEntry, info: ClipboardMediaInfo?) -> [DetailRow] {
        var rows = [DetailRow(label: L("clipboard.preview.type"), value: kindTitle(for: entry, info: info))]
        if let app = entry.kind == .voice ? "Typeflux" : entry.sourceAppName, !app.isEmpty {
            rows.append(DetailRow(label: L("clipboard.preview.source"), value: app))
        }
        rows.append(DetailRow(
            label: L("clipboard.preview.copiedAt"),
            value: entry.date.formatted(date: .abbreviated, time: .shortened)
        ))
        if entry.kind.isTextual, let text = entry.text {
            rows.append(DetailRow(
                label: L("clipboard.preview.size"), value: L("clipboard.entry.characters", text.count)
            ))
        } else if entry.byteSize > 0 {
            rows.append(DetailRow(
                label: L("clipboard.preview.size"),
                value: ByteCountFormatter.string(fromByteCount: entry.byteSize, countStyle: .file)
            ))
        }
        if entry.filePaths.count == 1, let path = entry.filePaths.first {
            rows.append(DetailRow(label: L("clipboard.preview.location"), value: path))
        }
        return rows
    }

    /// The first part of the row subtitle without the source and time, e.g. `PNG · 1400×1116`.
    private static func kindTitle(for entry: ClipboardEntry, info: ClipboardMediaInfo?) -> String {
        let parts = ClipboardEntryFormatter.details(for: entry, info: info)
        let trailing = 1 + ((entry.sourceAppName?.isEmpty == false) ? 1 : 0)
            + ((!entry.kind.isTextual && entry.byteSize > 0) ? 1 : 0)
        return parts.dropLast(trailing).joined(separator: " · ")
    }

    /// Text shown in the pane; very long clips are cut so layout stays fast.
    static func previewText(_ text: String) -> String {
        let limit = 20000
        // UTF-8 length is O(1) and never below the character count, so short text skips counting.
        guard text.utf8.count > limit, text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
