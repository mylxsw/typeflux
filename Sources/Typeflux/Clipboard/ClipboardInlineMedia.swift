import AVKit
import SwiftUI

/// The content a media row shows in place of a title: image thumbnails, a video frame or an
/// audio waveform. It grows in place when the row is selected; video and audio then play inline.
struct ClipboardInlineMedia: View {
    let entry: ClipboardEntry
    let info: ClipboardMediaInfo?
    let isSelected: Bool
    let isMissing: Bool

    static let height: CGFloat = 64
    static let selectedImageHeight: CGFloat = 168
    static let selectedVideoHeight: CGFloat = 190
    static let stripTileSize: CGFloat = 56
    static let stripLimit = 3

    var body: some View {
        switch entry.kind {
        case .image: image
        case .images: images
        case .video: video
        case .audio: audio
        default: EmptyView()
        }
    }

    /// An unselected image keeps its aspect ratio at row height, within sane bounds.
    static func thumbnailWidth(for pixelSize: CGSize?) -> CGFloat {
        guard let size = pixelSize, size.width > 0, size.height > 0 else { return 96 }
        return min(max(height * size.width / size.height, 48), 220)
    }

    // MARK: - Kinds

    private var image: some View {
        let expanded = isSelected && !isMissing
        return ZStack(alignment: .bottomTrailing) {
            if isMissing {
                ClipboardMissingThumbnail()
            } else {
                ClipboardThumbnailView(
                    url: entry.contentURLs.first, maxPixelSize: expanded ? 900 : 240, placeholder: "photo",
                    contentMode: expanded ? .fit : .fill
                )
            }
            if expanded, let size = entry.imagePixelSize {
                ClipboardMediaChip(text: "\(Int(size.width)) × \(Int(size.height))")
                    .padding(6)
            }
        }
        .frame(width: expanded ? nil : Self.thumbnailWidth(for: entry.imagePixelSize),
               height: expanded ? Self.selectedImageHeight : Self.height)
        .frame(maxWidth: expanded ? .infinity : nil, alignment: .leading)
        .clipboardMediaFrame()
    }

    @ViewBuilder
    private var images: some View {
        let urls = Array(entry.fileURLs.enumerated())
        if isSelected {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(urls.prefix(6), id: \.offset) { _, url in
                    ClipboardThumbnailView(url: url, maxPixelSize: 300, placeholder: "photo")
                        .frame(height: 92)
                        .clipboardMediaFrame()
                }
            }
        } else {
            HStack(spacing: 4) {
                ForEach(urls.prefix(Self.stripLimit), id: \.offset) { _, url in
                    ClipboardThumbnailView(url: url, maxPixelSize: 168, placeholder: "photo")
                        .frame(width: Self.stripTileSize, height: Self.stripTileSize)
                        .clipboardMediaFrame()
                }
                if urls.count > Self.stripLimit {
                    Text(verbatim: "+\(urls.count - Self.stripLimit)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 40, minHeight: Self.stripTileSize)
                        .background(
                            Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
            }
        }
    }

    @ViewBuilder
    private var video: some View {
        if isSelected, !isMissing, let url = entry.fileURLs.first {
            ClipboardMediaPlayer(url: url)
                .frame(maxWidth: .infinity)
                .frame(height: Self.selectedVideoHeight)
                .background(Color.black)
                .clipboardMediaFrame()
        } else {
            ZStack {
                if isMissing {
                    ClipboardMissingThumbnail()
                } else {
                    ClipboardThumbnailView(url: entry.fileURLs.first, maxPixelSize: 240, placeholder: "film")
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
                }
            }
            .frame(width: 114, height: Self.height)
            .overlay(alignment: .bottomTrailing) {
                if let duration = info?.duration {
                    ClipboardMediaChip(text: ClipboardEntryFormatter.duration(duration)).padding(4)
                }
            }
            .clipboardMediaFrame()
        }
    }

    @ViewBuilder
    private var audio: some View {
        if isSelected, !isMissing, let url = entry.fileURLs.first {
            ClipboardAudioPlayerView(url: url, duration: info?.duration)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
                ClipboardWaveformView(url: isMissing ? nil : entry.fileURLs.first, bars: 48)
                    .frame(height: 24)
                if let duration = info?.duration {
                    Text(ClipboardEntryFormatter.duration(duration))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(StudioTheme.textSecondary)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .frame(width: 260, height: 40)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

/// Rounded corners and a hairline so thumbnails read as objects on any row background.
private struct ClipboardMediaFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
    }
}

extension View {
    func clipboardMediaFrame() -> some View {
        modifier(ClipboardMediaFrame())
    }
}

/// A small dark label over media, e.g. a duration or pixel size.
struct ClipboardMediaChip: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Stands in for a preview whose file was moved or deleted.
struct ClipboardMissingThumbnail: View {
    var body: some View {
        ZStack {
            AskTheme.raisedSurface
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
        }
    }
}

/// An inline AVKit player for copied video files. Playback stops when the row collapses.
struct ClipboardMediaPlayer: NSViewRepresentable {
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
