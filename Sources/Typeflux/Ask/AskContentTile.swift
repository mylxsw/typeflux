import AppKit
import SwiftUI

/// What one large content tile shows (GUL-464). Content the user hands over (images,
/// documents, the screenshot, selected text) is shown as a preview big enough to check
/// before sending; skills and MCP servers are instructions and stay out of the tray.
struct AskContentTileModel: Equatable {
    enum Style: Equatable {
        /// A picture: an attached image or the screenshot.
        case image
        /// A document page drawn from its extracted text.
        case document
        case folder
        /// Quoted text, drawn wider than a square.
        case selection
        /// Still being read or captured.
        case pending
        /// Could not be included; `caption` says why.
        case warning
    }

    var style: Style
    var title: String
    var caption: String?
    /// The first lines of a document or the selected text.
    var excerpt: String?
    /// The file type on a document page, e.g. "PDF".
    var badge: String?

    /// The longest excerpt a tile draws; a tile shows a handful of lines.
    static let excerptLimit = 240

    static func make(_ attachment: AskAttachment) -> Self {
        switch attachment.kind {
        case .image:
            return .init(style: .image, title: attachment.name, caption: sizeCaption(attachment.byteSize))
        case .folder:
            return .init(style: .folder, title: attachment.name, caption: L("ask.attach.folderReadOnly"),
                         excerpt: attachment.path)
        case .file:
            return .init(style: .document, title: attachment.name,
                         caption: AskAttachmentStrip.caption(attachment) ?? sizeCaption(attachment.byteSize),
                         excerpt: excerpt(attachment.text),
                         badge: badge(for: attachment.name, pages: attachment.pages))
        }
    }

    /// A tile for the screenshot or selected text, following the item's state.
    static func make(_ item: AskContextItem, capturing: Bool = false) -> Self {
        switch item.style {
        case .warning, .unavailable:
            return .init(style: .warning, title: item.title, caption: item.detail)
        case .active, .neutral:
            break
        }
        switch item.kind {
        case .selection:
            return .init(style: .selection, title: item.sourceAppName ?? item.title, excerpt: excerpt(item.detail))
        case .screenshot:
            return .init(style: capturing ? .pending : .image, title: item.title, caption: item.detail)
        case .source, .memory:
            return .init(style: .document, title: item.title, caption: item.detail)
        }
    }

    /// Collapses whitespace so a tile's few lines carry words, not blank lines.
    static func excerpt(_ text: String?) -> String? {
        guard let text else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        return words.count > excerptLimit ? String(words.prefix(excerptLimit)) + "…" : words
    }

    /// The extension in capitals, or "PDF" for a paged file without one.
    static func badge(for name: String, pages: Int?) -> String? {
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, ext.count <= 5 { return ext.uppercased() }
        return pages != nil ? "PDF" : nil
    }

    static func sizeCaption(_ bytes: Int?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Badge colours by family, so a PDF and a spreadsheet read apart at a glance.
    static func badgeColor(_ badge: String?) -> Color {
        switch badge {
        case "PDF": Color(red: 0.90, green: 0.28, blue: 0.30)
        case "XLS", "XLSX", "CSV", "NUMBERS": Color(red: 0.20, green: 0.62, blue: 0.36)
        case "DOC", "DOCX", "PAGES", "RTF": Color(red: 0.24, green: 0.47, blue: 0.90)
        case "MD", "TXT": Color(red: 0.37, green: 0.42, blue: 0.82)
        default: Color(red: 0.45, green: 0.47, blue: 0.55)
        }
    }
}

/// A large square preview of something that rides with a message. Clicking opens it;
/// the remove button appears on hover and is always reachable with VoiceOver.
struct AskContentTile: View {
    let tile: AskContentTileModel
    var image: NSImage?
    var side: CGFloat = AskContentTile.composerSide
    /// Marks the screenshot as the live screen rather than a file.
    var screen = false
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?
    var actionLabel: String?
    var onAction: (() -> Void)?
    @State private var hovering = false

    static let composerSide: CGFloat = 112
    static let sentSide: CGFloat = 156
    static let corner: CGFloat = 12

    var width: CGFloat { tile.style == .selection || tile.style == .warning ? side * 1.5 : side }

    var body: some View {
        face
            .frame(width: width, height: side)
            .background(AskTheme.hoverFill.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(tile.style == .warning ? StudioTheme.warning.opacity(0.6) : AskTheme.border,
                              lineWidth: 0.5))
            .overlay(alignment: .topTrailing) { removeButton }
            .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .onTapGesture { onOpen?() }
            .onHover { hovering = $0 }
            .help([tile.title, tile.caption].compactMap { $0 }.joined(separator: " · "))
            .accessibilityElement(children: .contain)
            .accessibilityLabel([tile.title, tile.caption].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
            .accessibilityAction { onOpen?() }
    }

    @ViewBuilder private var face: some View {
        switch tile.style {
        case .image: imageFace
        case .document: documentFace
        case .folder: folderFace
        case .selection: selectionFace
        case .pending:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(tile.title).font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary).lineLimit(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .warning: warningFace
        }
    }

    private var imageFace: some View {
        ZStack(alignment: .bottomLeading) {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: width, height: side).clipped()
            } else {
                Image(systemName: screen ? "display" : "photo")
                    .font(.system(size: 22)).foregroundStyle(StudioTheme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .center, endPoint: .bottom)
            HStack(spacing: 4) {
                if screen { Image(systemName: "display").font(.system(size: 9, weight: .semibold)) }
                Text(tile.title).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.bottom, 6)
        }
    }

    private var documentFace: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                Text(tile.excerpt ?? "")
                    .font(.system(size: 6.5))
                    .foregroundStyle(Color.black.opacity(0.62))
                    .lineSpacing(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 7).padding(.top, 7)
                    .background(Color(white: 0.985))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                if let badge = tile.badge {
                    Text(badge)
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(AskContentTileModel.badgeColor(badge), in: RoundedRectangle(cornerRadius: 3))
                        .padding(5)
                }
            }
            .padding(.horizontal, 9).padding(.top, 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(tile.title).font(.system(size: 11, weight: .medium)).foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                if let caption = tile.caption {
                    Text(caption).font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 5)
        }
    }

    private var folderFace: some View {
        VStack(spacing: 6) {
            Image(systemName: "folder.fill").font(.system(size: 30)).foregroundStyle(AskTheme.accent.opacity(0.8))
            Text(tile.title).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
            if let caption = tile.caption {
                Text(caption).font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectionFace: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(tile.title, systemImage: "text.quote")
                .font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
            Text(tile.excerpt ?? "")
                .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
                .lineLimit(5)
                .padding(.leading, 7)
                .overlay(alignment: .leading) { Rectangle().fill(AskTheme.border).frame(width: 2) }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var warningFace: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(tile.title, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(StudioTheme.warning).lineLimit(2)
            if let caption = tile.caption {
                Text(caption).font(.system(size: 10.5)).foregroundStyle(StudioTheme.textSecondary).lineLimit(3)
            }
            Spacer(minLength: 0)
            if let actionLabel, let onAction {
                Button(actionLabel, action: onAction)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StudioTheme.warning)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ask.content.screenshot.action")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var removeButton: some View {
        if let onRemove {
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Color.black.opacity(0.6), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(5)
            .opacity(hovering ? 1 : 0)
            .help(L("ask.remove"))
            .accessibilityLabel(L("ask.remove") + " " + tile.title)
        }
    }
}

/// The full view of an attached image or document, opened from its tile or chip.
struct AskAttachmentPreview: View {
    let attachment: AskAttachment
    var image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 650, maxHeight: 520).padding()
        } else if attachment.image != nil {
            Text(L("ask.image.previewUnavailable")).padding()
        } else {
            ScrollView {
                Text(String((attachment.text ?? "").prefix(20000)))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 480, height: 320)
            .padding(14)
        }
    }
}

/// An attachment as a tile with its own image decoding and preview popover.
struct AskAttachmentTile: View {
    let attachment: AskAttachment
    var side: CGFloat = AskContentTile.composerSide
    var onRemove: (() -> Void)?
    /// Replaces the preview popover, e.g. a sent file opening in the side panel.
    var onOpen: (() -> Void)?
    @State private var previewing = false
    @StateObject private var imageModel = AskContextImageModel()
    @Environment(\.askContextImageAccess) private var imageAccess
    private var image: NSImage? { imageModel.displayed(attachment.image, access: imageAccess) }

    var body: some View {
        AskContentTile(tile: AskContentTileModel.make(attachment), image: image, side: side,
                       onOpen: open, onRemove: onRemove)
            .popover(isPresented: $previewing) { AskAttachmentPreview(attachment: attachment, image: image) }
            .task(id: AskContextImageModel.Identity(source: attachment.image, epoch: imageAccess.epoch)) {
                await imageModel.load(attachment.image, access: imageAccess)
            }
            .onDisappear { imageModel.cancel(); previewing = false }
            .accessibilityIdentifier("ask.content.attachment")
    }

    private func open() {
        if let onOpen {
            onOpen()
        } else if attachment.kind == .folder, let path = attachment.path {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            previewing = true
        }
    }
}
