import SwiftUI

/// One clipboard panel row: the source app's icon, then the content. Media rows show the content
/// itself (thumbnails, a video frame, a waveform); the selected row expands its text or preview.
struct ClipboardPanelRow: View {
    @ObservedObject var model: ClipboardPanelModel
    let entry: ClipboardEntry
    let index: Int
    let isSelected: Bool
    let isHovered: Bool
    @State private var info: ClipboardMediaInfo?

    var body: some View {
        let missing = model.isMissing(entry)
        HStack(alignment: .top, spacing: 11) {
            ClipboardEntryLeadingIcon(entry: entry)
                .opacity(missing ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 2) {
                content(missing: missing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.yellow)
                }
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AskTheme.accentSoft : isHovered ? AskTheme.hoverFill : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.perform(.paste, at: index) }
        .onTapGesture { model.select(index: index) }
        .contextMenu { contextMenu }
        .modifier(AskLauncherNumberBadge(number: AskLauncherNumberShortcuts.number(at: index)))
        .task(id: entry.id) { await loadInfo() }
    }

    @ViewBuilder
    private func content(missing: Bool) -> some View {
        if entry.hasInlineMedia {
            ClipboardInlineMedia(entry: entry, info: info, isSelected: isSelected, isMissing: missing)
                .opacity(missing ? 0.55 : 1)
                .padding(.top, 1)
                .padding(.bottom, 3)
            subtitle(missing: missing, caption: entry.mediaCaption)
            if isSelected, missing {
                ClipboardEntryPreview(entry: entry, isMissing: true)
                    .padding(.top, 4)
            }
        } else if entry.kind == .pdf {
            HStack(alignment: .center, spacing: 10) {
                ClipboardPDFThumbnail(url: missing ? nil : entry.fileURLs.first, isExpanded: isSelected)
                VStack(alignment: .leading, spacing: 2) {
                    title(missing: missing)
                    subtitle(missing: missing)
                    if isSelected, let path = entry.filePaths.first {
                        Text(path)
                            .font(.system(size: 11))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                }
            }
        } else {
            title(missing: missing)
            subtitle(missing: missing)
            if isSelected, !entry.kind.isTextual {
                ClipboardEntryPreview(entry: entry, isMissing: missing)
                    .padding(.top, 6)
            }
        }
    }

    private func title(missing: Bool) -> some View {
        // A row never shows more than a few lines; don't lay out megabytes of text.
        Text(String(entry.title.prefix(2000)))
            .font(entry.kind == .code ? .system(size: 12.5, design: .monospaced) : .system(size: 13.5))
            .lineLimit(isSelected && entry.kind.isTextual ? 4 : 1)
            .truncationMode(.tail)
            .opacity(missing ? 0.55 : 1)
    }

    /// Kind, size, source and time; media rows lead with the file name, which truncates first.
    private func subtitle(missing: Bool, caption: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let caption {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .truncationMode(.middle)
                Circle().frame(width: 2, height: 2)
            }
            let details = ClipboardEntryFormatter.details(for: entry, info: info)
            ForEach(Array(details.enumerated()), id: \.offset) { offset, part in
                if offset > 0 {
                    Circle().frame(width: 2, height: 2)
                }
                Text(part).layoutPriority(1)
            }
            if missing {
                Circle().frame(width: 2, height: 2)
                Text(L("clipboard.entry.missing")).foregroundStyle(Color.orange)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(StudioTheme.textSecondary)
        .lineLimit(1)
    }

    private func loadInfo() async {
        guard [.video, .audio, .pdf].contains(entry.kind), let url = entry.fileURLs.first else { return }
        info = ClipboardMediaInfoProvider.shared.cachedInfo(for: url)
        if info == nil {
            info = await ClipboardMediaInfoProvider.shared.info(for: url, kind: entry.kind)
        }
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

/// The leading icon: the app the content was copied from (Typeflux for voice results), or the
/// kind's tile when the source is unknown, as for records captured before sources were kept.
struct ClipboardEntryLeadingIcon: View {
    let entry: ClipboardEntry
    var iconProvider = ClipboardAppIconProvider.shared

    var body: some View {
        if let icon = iconProvider.icon(for: entry) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 28, height: 28)
                .frame(width: 32, height: 32)
                .help(entry.kind == .voice ? "Typeflux" : entry.sourceAppName ?? "")
        } else {
            ClipboardEntryTile(entry: entry)
        }
    }
}

/// A symbol or file badge for the entry's kind. Media rows already show their content, so they
/// get a plain symbol rather than a second thumbnail.
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
        case .image:
            symbol("photo")
        case .images:
            symbol("photo.on.rectangle")
        case .video:
            symbol("film")
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
    /// The file `image` shows; a size change for the same file keeps it visible while reloading.
    @State private var imagePath: String?

    var body: some View {
        ZStack {
            AskTheme.raisedSurface
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Image(systemName: placeholder).foregroundStyle(.tertiary)
            }
        }
        // A selected row asks for a larger size of the same file; reload it at that size.
        .task(id: "\(url?.path ?? "")#\(Int(maxPixelSize))") {
            guard let url else { return }
            if imagePath != url.path { image = nil }
            let provider = ClipboardThumbnailProvider.shared
            var loaded = provider.cachedThumbnail(for: url, maxPixelSize: maxPixelSize)
            if loaded == nil {
                loaded = await provider.thumbnail(for: url, maxPixelSize: maxPixelSize)
            }
            if let loaded {
                image = loaded
                imagePath = url.path
            }
        }
    }
}

/// The first page of a copied PDF, enlarged on the selected row.
struct ClipboardPDFThumbnail: View {
    let url: URL?
    let isExpanded: Bool

    var body: some View {
        Group {
            if url == nil {
                ClipboardMissingThumbnail()
            } else {
                ClipboardThumbnailView(url: url, maxPixelSize: 360, placeholder: "doc", contentMode: .fit)
            }
        }
        .frame(width: isExpanded ? 92 : 50, height: isExpanded ? 120 : 64)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: isExpanded ? 4 : 2, y: 1)
    }
}
