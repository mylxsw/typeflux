import SwiftUI

/// One clipboard panel row: the source app's icon, then the content. Media rows show the content
/// itself (thumbnails, a video frame, a waveform). Rows keep their height when selected; the
/// preview pane shows the full text or a large preview instead, so moving the selection never
/// re-lays out the list.
///
/// The row takes plain values rather than the panel model and compares them in `==`, so a
/// selection change redraws only the two rows whose highlight changed.
struct ClipboardPanelRow: View, Equatable {
    let entry: ClipboardEntry
    let index: Int
    let isSelected: Bool
    let isHovered: Bool
    let isMissing: Bool
    /// The `⌘` number badge while the hints are showing.
    var number: Int?
    var onClick: (Int) -> Void = { _ in }
    var onPerform: (ClipboardEntryAction) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.index == rhs.index && lhs.isSelected == rhs.isSelected
            && lhs.isHovered == rhs.isHovered && lhs.isMissing == rhs.isMissing && lhs.number == rhs.number
    }

    var body: some View {
        ClipboardMediaValue(request: isMissing ? nil : .info(entry)) { value in row(info: value?.info) }
    }

    private func row(info: ClipboardMediaInfo?) -> some View {
        HStack(alignment: .center, spacing: 11) {
            ClipboardEntryLeadingIcon(entry: entry)
                .opacity(isMissing ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 2) {
                content(info: info)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.yellow)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AskTheme.launcherSelection : isHovered ? AskTheme.hoverFill : Color.clear)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AskTheme.launcherSelectionEdge, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .overlay(ClipboardRowClickArea(onClick: onClick))
        .accessibilityAction { onClick(1) }
        .onHover(perform: onHover)
        .contextMenu { contextMenu }
        .modifier(AskLauncherNumberBadge(number: number))
    }

    @ViewBuilder
    private func content(info: ClipboardMediaInfo?) -> some View {
        if entry.hasInlineMedia {
            ClipboardInlineMedia(entry: entry, info: info, isExpanded: false, isMissing: isMissing)
                .opacity(isMissing ? 0.55 : 1)
                .padding(.top, 1)
                .padding(.bottom, 3)
            subtitle(caption: entry.mediaCaption, info: info)
        } else if entry.kind == .pdf {
            HStack(alignment: .center, spacing: 10) {
                ClipboardPDFThumbnail(url: isMissing ? nil : entry.fileURLs.first, isExpanded: false)
                VStack(alignment: .leading, spacing: 2) {
                    title
                    subtitle(info: info)
                }
            }
        } else {
            title
            subtitle(info: info)
        }
    }

    private var title: some View {
        // A row shows one line; don't lay out megabytes of text.
        Text(String(entry.title.prefix(300)))
            .font(entry.kind == .code ? .system(size: 12.5, design: .monospaced) : .system(size: 13.5))
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(isMissing ? 0.55 : 1)
    }

    /// Kind, size, source and time; media rows lead with the file name, which truncates first.
    private func subtitle(caption: String? = nil, info: ClipboardMediaInfo?) -> some View {
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
            if isMissing {
                Circle().frame(width: 2, height: 2)
                Text(L("clipboard.entry.missing")).foregroundStyle(Color.orange)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(StudioTheme.textSecondary)
        .lineLimit(1)
    }

    /// Separators before previews, the app filter and pinning: paste and copy come first,
    /// destructive actions last.
    static func startsMenuGroup(_ action: ClipboardEntryAction, after previous: ClipboardEntryAction) -> Bool {
        switch action {
        case .saveSnippet, .editSnippet, .togglePin: true
        case .quickLook, .showOnlyApp: previous == .copy
        default: false
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        let actions = ClipboardEntryAction.available(for: entry)
        ForEach(Array(actions.enumerated()), id: \.offset) { offset, action in
            if offset > 0, Self.startsMenuGroup(action, after: actions[offset - 1]) {
                Divider()
            }
            Button {
                onPerform(action)
            } label: {
                Text(action.title(for: entry))
            }
            .disabled(action.requiresContent && isMissing)
        }
    }
}

/// The leading icon: the app the content was copied from (Typeflux for voice results), or the
/// kind's tile when the source is unknown, as for records captured before sources were kept.
struct ClipboardEntryLeadingIcon: View {
    let entry: ClipboardEntry

    var body: some View {
        AskNativeIconImage(icon: ClipboardAppIconProvider.target(for: entry)) { icon in
            if let icon {
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
    @Environment(\.askContextImageAccess) private var access
    @Environment(\.clipboardThumbnailDecoder) private var decode
    @Environment(\.clipboardThumbnailCache) private var cache

    var body: some View {
        let url = self.url, edge = maxPixelSize, decode = self.decode
        let cached = access.allows() ? url.flatMap { cache?.image(for: $0, edge: edge) } : nil
        return AskContextImage(source: url?.absoluteString,
            model: AskContextImageModel(maximumEdge: edge.isFinite && edge >= 1 && edge <= 900 ? Int(edge) : 1, decode: { _ in
                guard let url else { throw CancellationError() }
                return try await decode(url, edge)
            })) { image in
                ZStack {
                    AskTheme.raisedSurface
                    if let image = image ?? cached { Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode) }
                    else { Image(systemName: placeholder).foregroundStyle(.tertiary) }
                }
            }
            .id(Identity(url: url, edge: edge.isFinite ? edge : -1, epoch: access.epoch))
    }
    private struct Identity: Hashable { let url: URL?; let edge: CGFloat; let epoch: UUID? }

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
