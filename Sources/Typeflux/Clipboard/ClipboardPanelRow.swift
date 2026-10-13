import SwiftUI

/// Compact results use a kind icon, one content line, source/time and an always-visible quick-paste key.
/// Full text, thumbnails and media controls live in the preview pane; selection never resizes a row.
///
/// The row takes plain values rather than the panel model and compares them in `==`, so a
/// selection change redraws only the two rows whose highlight changed.
struct ClipboardPanelRow: View, Equatable {
    let entry: ClipboardEntry
    let index: Int
    let isSelected: Bool
    let isHovered: Bool
    let isMissing: Bool
    /// The `⌘` number of this visible row, independent of modifier-key state.
    var number: Int?
    var onClick: (Int) -> Void = { _ in }
    var onPerform: (ClipboardEntryAction) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }
    @Environment(\.interfaceStyle) private var style

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.index == rhs.index && lhs.isSelected == rhs.isSelected
            && lhs.isHovered == rhs.isHovered && lhs.isMissing == rhs.isMissing && lhs.number == rhs.number
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ClipboardEntryTile(entry: entry, size: style == .classic ? 22 : 28, selected: isSelected)
                .opacity(isMissing ? 0.55 : 1)
            title.frame(maxWidth: .infinity, alignment: .leading)
            if isMissing {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(isSelected ? rowText : TypefluxColor.warning.color)
                    .help(L("clipboard.entry.missing"))
            }
            Text(ClipboardEntryFormatter.rowMetadata(for: entry))
                .font(.subheadline)
                .foregroundStyle(TypefluxSpotlightRow.labelColor(selected: isSelected, secondary: true))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 140, alignment: .trailing)
            if entry.isPinned {
                Image(systemName: "pin.fill").font(.footnote)
                    .foregroundStyle(isSelected ? rowText : TypefluxColor.secondaryLabel.color)
            }
            Text(number.map { "⌘\($0)" } ?? "")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(TypefluxSpotlightRow.labelColor(selected: isSelected, secondary: true))
                .frame(width: 24, alignment: .trailing)
                .accessibilityHidden(number == nil)
        }
        .padding(.horizontal, 10)
        .frame(height: style == .classic ? 34 : 44)
        .background(
            RoundedRectangle(cornerRadius: TypefluxRadius.sidebarRow.value(for: style), style: .continuous)
                .fill(isSelected ? TypefluxColor.selection.color
                    : isHovered ? TypefluxColor.controlBackground.color : Color.clear)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: TypefluxRadius.sidebarRow.value(for: style), style: .continuous)
                    .strokeBorder(TypefluxColor.separator.color, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        }
        .foregroundStyle(rowText)
        .contentShape(Rectangle())
        .overlay(ClipboardRowClickArea(onClick: onClick))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("clipboard.result." + entry.id)
        .accessibilityAction { onClick(1) }
        .onHover(perform: onHover)
        .contextMenu { contextMenu }
        .help(ClipboardEntryFormatter.details(for: entry).joined(separator: " · "))
    }

    private var rowText: Color {
        isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : TypefluxColor.label.color
    }

    private var title: some View {
        // A row shows one line; don't lay out megabytes of text.
        Text(String(entry.title.prefix(300)))
            .font(entry.kind == .code ? .body.monospaced() : .body)
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(isMissing ? 0.55 : 1)
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
    var size: CGFloat = 32
    var selected = false
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        if entry.snippet != nil {
            symbol("scissors")
        } else {
            kindIcon
        }
    }

    @ViewBuilder private var kindIcon: some View {
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
            .font(.body.weight(.medium))
            .foregroundStyle(TypefluxSpotlightRow.labelColor(selected: selected, secondary: true))
            .frame(width: size, height: size)
            .background(TypefluxColor.label.color.opacity(0.06), in: RoundedRectangle(
                cornerRadius: TypefluxRadius.navigationIcon.value(for: style), style: .continuous))
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
            TypefluxColor.windowBackground.color
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
