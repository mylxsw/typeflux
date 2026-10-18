import SwiftUI

/// One card on the clipboard shelf: a header in the source app's color with the kind, time and
/// app icon, the content itself, and a footer with its size. Like `ClipboardPanelRow`, the card
/// takes plain values and compares them in `==`, so moving the selection redraws two cards.
struct ClipboardShelfCard: View, Equatable {
    static let width: CGFloat = 224
    static let height: CGFloat = 240
    static let headerHeight: CGFloat = 50
    static let footerHeight: CGFloat = 26
    static let cornerRadius: CGFloat = 14
    /// Text past this many characters is never laid out on a card.
    static let textLimit = 800

    let entry: ClipboardEntry
    let index: Int
    let isSelected: Bool
    let isHovered: Bool
    let isMissing: Bool
    var number: Int?
    var onClick: (Int) -> Void = { _ in }
    var onPerform: (ClipboardEntryAction) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.index == rhs.index && lhs.isSelected == rhs.isSelected
            && lhs.isHovered == rhs.isHovered && lhs.isMissing == rhs.isMissing && lhs.number == rhs.number
    }

    var body: some View {
        ClipboardMediaValue(request: isMissing ? nil : .info(entry)) { value in card(info: value?.info) }
    }

    private func card(info: ClipboardMediaInfo?) -> some View {
        VStack(spacing: 0) {
            ClipboardShelfCardHeader(entry: entry)
            ClipboardShelfCardBody(entry: entry, info: info, isMissing: isMissing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            footer(info: info)
        }
        .frame(width: Self.width, height: Self.height)
        .background(AskTheme.launcherSurface)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                              lineWidth: isSelected ? 3 : 0.5)
                .allowsHitTesting(false)
        }
        .shadow(color: isSelected ? Color.accentColor.opacity(0.3) : .black.opacity(0.18),
                radius: isSelected ? 10 : 2, y: isSelected ? 6 : 1)
        .offset(y: isSelected ? -4 : isHovered ? -2 : 0)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .contentShape(Rectangle())
        .overlay(ClipboardRowClickArea(onClick: onClick))
        .onHover(perform: onHover)
        .contextMenu { ClipboardEntryContextMenu(entry: entry, isMissing: isMissing, onPerform: onPerform) }
        .modifier(AskLauncherShortcutBadge(
            key: number.flatMap { (1 ... 9).contains($0) ? String($0) : nil },
            leadingInset: 10, topInset: Self.height - Self.footerHeight + 4.5
        ))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(for: entry))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onClick(1) }
    }

    private func footer(info: ClipboardMediaInfo?) -> some View {
        Text(isMissing ? L("clipboard.entry.missing") : Self.footerText(for: entry, info: info))
            .font(.system(size: 11))
            .foregroundStyle(isMissing ? Color.orange : StudioTheme.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: Self.footerHeight)
            .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
    }

    /// The row subtitle without the source app and time, which the header already shows:
    /// e.g. `128 characters`, `PNG · 1400×1116 · 842 KB`, `PDF · 12 pages · 2.3 MB`.
    static func footerText(for entry: ClipboardEntry, info: ClipboardMediaInfo?) -> String {
        if entry.snippet != nil || entry.kind.isTextual {
            if entry.kind == .link, let host = entry.text.flatMap(URL.init(string:))?.host { return host }
            return L("clipboard.entry.characters", entry.text?.count ?? 0)
        }
        var parts = ClipboardEntryFormatter.details(for: entry, info: info)
        parts.removeLast()
        if let app = entry.sourceAppName, !app.isEmpty, parts.last == app { parts.removeLast() }
        return parts.joined(separator: " · ")
    }

    /// The kind and the content, e.g. "Text, Meeting at 10".
    static func accessibilityLabel(for entry: ClipboardEntry) -> String {
        "\(ClipboardShelfCardHeader.kindTitle(for: entry)), \(String(entry.title.prefix(200)))"
    }
}

/// The colored top of a card. The color comes from the source app's icon once it has loaded.
struct ClipboardShelfCardHeader: View {
    let entry: ClipboardEntry

    var body: some View {
        AskNativeIconImage(icon: ClipboardAppIconProvider.target(for: entry)) { icon in
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.kindTitle(for: entry))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(Self.subtitle(for: entry))
                        .font(.system(size: 11))
                        .opacity(0.82)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .rotationEffect(.degrees(45))
                        .accessibilityLabel(L("clipboard.section.pinned"))
                }
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                        .help(entry.kind == .voice ? "Typeflux" : entry.sourceAppName ?? "")
                }
            }
            .foregroundStyle(.white)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(height: ClipboardShelfCard.headerHeight)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: Self.color(for: entry, icon: icon)))
        }
    }

    @MainActor
    static func color(for entry: ClipboardEntry, icon: NSImage?) -> NSColor {
        if entry.snippet != nil { return ClipboardAppAccent.snippet }
        if entry.kind == .voice { return ClipboardAppAccent.voice }
        guard let icon, let bundleID = entry.sourceBundleID else { return ClipboardAppAccent.neutral }
        return ClipboardAppAccent.color(for: bundleID, icon: icon)
    }

    /// A snippet shows its name; everything else its kind.
    static func kindTitle(for entry: ClipboardEntry) -> String {
        if let snippet = entry.snippet { return snippet.name }
        switch entry.kind {
        case .pdf: return "PDF"
        case .document: return ClipboardContentClassifier.badge(forFilePath: entry.filePaths.first ?? "")
        default: return L(kindKey(entry.kind))
        }
    }

    private static func kindKey(_ kind: ClipboardEntryKind) -> String {
        switch kind {
        case .voice: "clipboard.kind.voice"
        case .text: "clipboard.kind.text"
        case .link: "clipboard.kind.link"
        case .code: "clipboard.kind.code"
        case .image: "clipboard.entry.image"
        case .images: "clipboard.kind.image"
        case .video: "clipboard.kind.video"
        case .audio: "clipboard.kind.audio"
        case .pdf, .document, .files: "clipboard.kind.file"
        }
    }

    /// The copy time; a snippet shows its voice alias, or that it is kept permanently.
    static func subtitle(for entry: ClipboardEntry, now: Date = Date()) -> String {
        if let snippet = entry.snippet {
            if snippet.alias.isEmpty { return L("clipboard.snippet.permanent") }
            return L("clipboard.snippet.voiceAlias", snippet.alias)
        }
        return ClipboardEntryFormatter.relativeTime(from: entry.date, to: now)
    }
}

/// The content of a card, by kind.
struct ClipboardShelfCardBody: View {
    let entry: ClipboardEntry
    let info: ClipboardMediaInfo?
    let isMissing: Bool

    var body: some View {
        switch entry.kind {
        case .text, .voice: text
        case .code: code
        case .link: link
        case .image: image
        case .images: images
        case .video: video
        case .audio: audio
        case .pdf: pdf
        case .document, .files: files
        }
    }

    private var content: String {
        String((entry.text ?? entry.title).prefix(ClipboardShelfCard.textLimit))
    }

    private var text: some View {
        Text(content)
            .font(.system(size: 12.5))
            .lineSpacing(2)
            .lineLimit(entry.kind == .voice ? 7 : 8)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    private var code: some View {
        Text(content)
            .font(.system(size: 11.5, design: .monospaced))
            .lineLimit(10)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.primary.opacity(0.04))
    }

    private var link: some View {
        let url = entry.text.flatMap(URL.init(string:))
        return VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if let host = url?.host {
                Text(host)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            Text(content)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.accentColor)
                .lineLimit(3)
                .truncationMode(.middle)
        }
        .padding(12)
    }

    @ViewBuilder
    private var image: some View {
        if isMissing {
            ClipboardMissingThumbnail()
        } else {
            ClipboardThumbnailView(url: entry.contentURLs.first, maxPixelSize: 480, placeholder: "photo")
        }
    }

    private var images: some View {
        let urls = Array(entry.fileURLs.prefix(4).enumerated())
        let extra = entry.fileURLs.count - 4
        // A plain grid: four tiles never need lazy loading.
        return Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(Array(stride(from: 0, to: urls.count, by: 2)), id: \.self) { start in
                GridRow {
                    ForEach(urls[start ..< min(start + 2, urls.count)], id: \.offset) { offset, url in
                        tile(offset: offset, url: url, extra: extra)
                    }
                }
            }
        }
        .padding(6)
    }

    private func tile(offset: Int, url: URL, extra: Int) -> some View {
        Group {
            if isMissing {
                ClipboardMissingThumbnail()
            } else {
                ClipboardThumbnailView(url: url, maxPixelSize: 240, placeholder: "photo")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 76)
        .overlay {
            if offset == 3, extra > 0 {
                Text(verbatim: "+\(extra + 1)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.45))
            }
        }
        .clipboardMediaFrame()
    }

    private var video: some View {
        ZStack {
            if isMissing {
                ClipboardMissingThumbnail()
            } else {
                ClipboardThumbnailView(url: entry.fileURLs.first, maxPixelSize: 480, placeholder: "film")
                Image(systemName: "play.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let duration = info?.duration {
                ClipboardMediaChip(text: ClipboardEntryFormatter.duration(duration)).padding(8)
            }
        }
    }

    private var audio: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            ClipboardWaveformView(url: isMissing ? nil : entry.fileURLs.first, bars: 40)
                .frame(height: 48)
                .padding(.horizontal, 14)
            if let caption = entry.mediaCaption {
                Text(caption)
                    .font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.04))
    }

    private var pdf: some View {
        ClipboardPDFThumbnail(url: isMissing ? nil : entry.fileURLs.first, isExpanded: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.04))
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(entry.filePaths.prefix(4).enumerated()), id: \.offset) { _, path in
                HStack(spacing: 8) {
                    ClipboardFileBadge(path: path, compact: true)
                        .frame(width: 22, height: 26)
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if entry.filePaths.count > 4 {
                Text(L("clipboard.entry.fileCount", entry.filePaths.count))
                    .font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
        }
        .padding(12)
        .opacity(isMissing ? 0.5 : 1)
    }
}
