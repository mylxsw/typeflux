import AVKit
import PDFKit
import SwiftUI

/// The expanded preview of a selected non-text clipboard row.
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
        case .image:
            ZStack(alignment: .bottomTrailing) {
                ClipboardThumbnailView(
                    url: entry.contentURLs.first, maxPixelSize: 900, placeholder: "photo", contentMode: .fit
                )
                if let size = entry.imagePixelSize {
                    Text("\(Int(size.width)) × \(Int(size.height))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                        .padding(6)
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .images:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(entry.fileURLs.prefix(6), id: \.self) { url in
                    ClipboardThumbnailView(url: url, maxPixelSize: 300, placeholder: "photo")
                        .frame(height: 86)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        case .video:
            if let url = entry.fileURLs.first {
                ClipboardMediaPlayer(url: url)
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        case .audio:
            if let url = entry.fileURLs.first {
                ClipboardMediaPlayer(url: url)
                    .frame(height: 40)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        case .pdf, .document:
            if let url = entry.fileURLs.first {
                ClipboardDocumentPreview(url: url, isPDF: entry.kind == .pdf, byteSize: entry.byteSize)
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
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
            .padding(4)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .voice, .text, .link, .code:
            EmptyView()
        }
    }

    private static func fileSize(_ path: String) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        return size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : ""
    }
}

/// First-page thumbnail plus page count and location.
private struct ClipboardDocumentPreview: View {
    let url: URL
    let isPDF: Bool
    let byteSize: Int64
    @State private var pageCount: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ClipboardThumbnailView(url: url, maxPixelSize: 360, placeholder: "doc", contentMode: .fit)
                .frame(width: 92, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(url.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .task(id: url) {
            guard isPDF else { return }
            pageCount = await Task.detached { PDFDocument(url: url)?.pageCount }.value
        }
    }

    private var summary: String {
        var parts: [String] = []
        if let pageCount { parts.append(L("clipboard.preview.pages", pageCount)) }
        if byteSize > 0 { parts.append(ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }
}

/// An inline AVKit player for copied video and audio files. Playback stops when the row collapses.
private struct ClipboardMediaPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context _: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context _: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player?.pause()
            view.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator _: ()) {
        view.player?.pause()
        view.player = nil
    }
}
