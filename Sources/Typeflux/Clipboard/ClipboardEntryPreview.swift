import SwiftUI

/// The expanded preview of a selected document or file-list row, or the note that its file is gone.
struct ClipboardEntryPreview: View {
    let entry: ClipboardEntry
    let isMissing: Bool

    var body: some View {
        if isMissing {
            Label(L("clipboard.preview.missing"), systemImage: "exclamationmark.triangle")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.orange)
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch entry.kind {
        case .document:
            if let url = entry.fileURLs.first {
                ClipboardDocumentPreview(url: url, byteSize: entry.byteSize)
            }
        case .files:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(entry.filePaths, id: \.self) { path in
                    HStack(spacing: 8) {
                        ClipboardFileBadge(path: path, compact: true)
                            .frame(width: 26, height: 14)
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                        Text(Self.fileSize(path))
                            .font(.system(size: 11))
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
            .padding(4)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .voice, .text, .link, .code, .image, .images, .video, .audio, .pdf:
            // Text expands in the title; media and PDFs preview in the row itself.
            EmptyView()
        }
    }

    private static func fileSize(_ path: String) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        return size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : ""
    }
}

/// First-page thumbnail plus size and location.
private struct ClipboardDocumentPreview: View {
    let url: URL
    let byteSize: Int64

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ClipboardThumbnailView(url: url, maxPixelSize: 360, placeholder: "doc", contentMode: .fit)
                .frame(width: 92, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 6) {
                if byteSize > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text(url.path)
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
    }
}
