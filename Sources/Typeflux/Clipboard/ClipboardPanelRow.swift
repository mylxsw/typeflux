import SwiftUI

/// One clipboard panel row. The selected row expands to show its full text or a preview.
struct ClipboardPanelRow: View {
    @ObservedObject var model: ClipboardPanelModel
    let entry: ClipboardEntry
    let index: Int
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        let missing = model.isMissing(entry)
        HStack(alignment: .top, spacing: 11) {
            ClipboardEntryTile(entry: entry)
                .opacity(missing ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 2) {
                // A row never shows more than a few lines; don't lay out megabytes of text.
                Text(String(entry.title.prefix(2000)))
                    .font(entry.kind == .code ? .system(size: 12.5, design: .monospaced) : .system(size: 13.5))
                    .lineLimit(isSelected && entry.kind.isTextual ? 4 : 1)
                    .truncationMode(.tail)
                    .opacity(missing ? 0.55 : 1)
                subtitle(missing: missing)
                if isSelected, !entry.kind.isTextual {
                    ClipboardEntryPreview(entry: entry, isMissing: missing)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.yellow)
                }
                if isSelected || isHovered, index < 9 {
                    ClipboardKeycap(text: "⌘\(index + 1)")
                }
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.085 : (isHovered ? 0.04 : 0)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(isSelected ? 0.08 : 0), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.perform(.paste, at: index) }
        .onTapGesture { model.select(index: index) }
        .contextMenu { contextMenu }
    }

    private func subtitle(missing: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(ClipboardEntryFormatter.details(for: entry).enumerated()), id: \.offset) { offset, part in
                if offset > 0 {
                    Circle().frame(width: 2, height: 2)
                }
                Text(part)
            }
            if missing {
                Circle().frame(width: 2, height: 2)
                Text(L("clipboard.entry.missing")).foregroundStyle(Color.orange)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    @ViewBuilder
    private var contextMenu: some View {
        let actions = model.actions(for: entry)
        ForEach(Array(actions.enumerated()), id: \.offset) { offset, action in
            if offset > 0, action == .togglePin || (action == .quickLook && actions[offset - 1] == .copy) {
                Divider()
            }
            Button {
                model.perform(action, at: index)
            } label: {
                Text(action.title(for: entry))
            }
            .disabled(!model.isEnabled(action, for: entry))
        }
    }
}

/// The leading icon: a thumbnail for visual content, a type badge or symbol otherwise.
struct ClipboardEntryTile: View {
    let entry: ClipboardEntry
    private let size: CGFloat = 32

    var body: some View {
        switch entry.kind {
        case .voice:
            // Same neutral tile as the other text kinds; the waveform alone marks a voice result.
            symbol("waveform")
        case .text:
            symbol("doc.text")
        case .link:
            symbol("link")
        case .code:
            symbol("chevron.left.forwardslash.chevron.right")
        case .audio:
            symbol("music.note")
        case .image, .video:
            ClipboardThumbnailView(url: entry.contentURLs.first, maxPixelSize: 96, placeholder: "photo")
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    if entry.kind == .video {
                        Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                }
        case .images:
            stack(entry.fileURLs.prefix(3).map { url in
                AnyView(ClipboardThumbnailView(url: url, maxPixelSize: 72, placeholder: "photo"))
            })
        case .pdf, .document:
            ClipboardFileBadge(path: entry.filePaths.first ?? "")
                .frame(width: size, height: size)
        case .files:
            stack(entry.filePaths.prefix(3).map { AnyView(ClipboardFileBadge(path: $0, compact: true)) })
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func stack(_ views: [AnyView]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(views.enumerated()), id: \.offset) { offset, view in
                view
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.black.opacity(0.25))
                    )
                    .offset(x: CGFloat(offset) * 4.5, y: CGFloat(offset) * 4)
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }
}

/// A colored file-type badge, e.g. a red `PDF` or a blue `DOCX`.
struct ClipboardFileBadge: View {
    let path: String
    var compact = false

    var body: some View {
        let badge = ClipboardContentClassifier.badge(forFilePath: path)
        ZStack {
            if !compact {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06))
            }
            Text(badge)
                .font(.system(size: compact ? 6.5 : 8.5, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .frame(maxWidth: compact ? .infinity : nil, maxHeight: compact ? .infinity : nil)
                .background(ClipboardEntryFormatter.badgeColor(forFilePath: path),
                            in: RoundedRectangle(cornerRadius: compact ? 6 : 3, style: .continuous))
        }
    }
}

/// An asynchronously loaded thumbnail with a symbol placeholder.
struct ClipboardThumbnailView: View {
    let url: URL?
    let maxPixelSize: CGFloat
    let placeholder: String
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.06)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Image(systemName: placeholder).foregroundStyle(.tertiary)
            }
        }
        .task(id: url) {
            guard let url else { return }
            image = ClipboardThumbnailProvider.shared.cachedThumbnail(for: url, maxPixelSize: maxPixelSize)
            if image == nil {
                image = await ClipboardThumbnailProvider.shared.thumbnail(for: url, maxPixelSize: maxPixelSize)
            }
        }
    }
}
