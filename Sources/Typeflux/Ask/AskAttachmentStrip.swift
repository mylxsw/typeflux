import AppKit
import SwiftUI

/// The content that rides with the next message, shown above the editor: one
/// labelled capsule per item, each with its own remove button. The footer's
/// round toggles are the switches; this strip only shows what is actually
/// sent, so it never repeats a lit toggle in words.
enum AskAttachmentStrip {
    /// Items with content to show. Switched-off, failed and unavailable items
    /// stay as footer toggles only. Memory is left out because it is a setting
    /// with nothing to preview, and a screenshot waits until it is captured.
    /// Being in the strip already means "attached", so the screenshot takes
    /// the short label.
    static func attached(_ items: [AskContextItem], screenshotCaptured: Bool) -> [AskContextItem] {
        items.compactMap { item in
            switch item.kind {
            case .screenshot:
                guard item.style == .active, screenshotCaptured else { return nil }
                var item = item
                item.title = L("ask.context.screenshot")
                return item
            case .source: return item
            case .selection: return item.style == .active ? item : nil
            case .memory: return nil
            }
        }
    }

    /// The composer re-renders on every keystroke; the screenshot is a large
    /// data URL, so its thumbnail is decoded once per capture and reused.
    @MainActor private static var thumbnailCache: (key: ThumbnailKey, image: NSImage?)?

    struct ThumbnailKey: Equatable {
        var capturedAt: Date?
        var length: Int
    }

    @MainActor static func thumbnail(dataURL: String?, capturedAt: Date?,
                                     decode: (String) -> NSImage? = AskImage.decode) -> NSImage? {
        guard let dataURL else { return nil }
        let key = ThumbnailKey(capturedAt: capturedAt, length: dataURL.utf8.count)
        if let cached = thumbnailCache, cached.key == key { return cached.image }
        let image = decode(dataURL)
        thumbnailCache = (key, image)
        return image
    }
}

struct AskAttachmentStripView: View {
    let items: [AskContextItem]
    /// The attached screenshot, drawn as the chip's thumbnail.
    var screenshot: NSImage?
    var onPreview: () -> Void
    var onRemove: (AskContextItem.Kind) -> Void
    /// Files, images and folders the user added, after the captured context.
    var attachments: [AskAttachment] = []
    /// Files are still being read; a spinner holds their place.
    var loading = false
    var onRemoveAttachment: (String) -> Void = { _ in }
    /// Skills and MCP servers chosen with slash commands.
    var choices: [AskChosenTool] = []
    var onRemoveChoice: (AskChosenTool) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    AskAttachmentChip(item: item, thumbnail: item.kind == .screenshot ? screenshot : nil,
                                      onTap: item.kind == .screenshot ? onPreview : nil,
                                      onRemove: item.kind == .source ? nil : { onRemove(item.kind) })
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
                ForEach(attachments) { attachment in
                    AskAttachmentChip(item: AskAttachmentStrip.item(attachment),
                                      thumbnail: attachment.image.flatMap { AskAttachmentStrip.thumbnail(id: attachment.id, dataURL: $0) },
                                      caption: AskAttachmentStrip.caption(attachment),
                                      onRemove: { onRemoveAttachment(attachment.id) })
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
                ForEach(choices) { choice in
                    AskAttachmentChip(item: AskContextItem(kind: .source, systemImage: choice.symbol, style: .active,
                                                           title: choice.name, detail: choice.caption),
                                      caption: choice.caption,
                                      onRemove: { onRemoveChoice(choice) })
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
                if loading {
                    ProgressView().controlSize(.small)
                        .frame(width: AskAttachmentChip.height, height: AskAttachmentChip.height)
                        .accessibilityLabel(L("ask.attach.loading"))
                }
            }
            .padding(.vertical, 1)
        }
    }
}

extension AskAttachmentStrip {
    /// A chip model for an attachment; the kind only picks the remove behaviour.
    static func item(_ attachment: AskAttachment) -> AskContextItem {
        AskContextItem(kind: .source, systemImage: symbol(attachment), style: .active, title: attachment.name,
                       detail: attachment.kind == .folder ? attachment.path : attachment.name)
    }

    static func symbol(_ attachment: AskAttachment) -> String {
        switch attachment.kind {
        case .image: return "photo"
        case .folder: return "folder"
        case .file: return attachment.pages != nil ? "doc.richtext" : "doc.text"
        }
    }

    /// Quiet facts after the name: pages, truncation, or that a folder is read-only.
    static func caption(_ attachment: AskAttachment) -> String? {
        switch attachment.kind {
        case .folder: return L("ask.attach.folderReadOnly")
        case .image: return nil
        case .file:
            var parts: [String] = []
            if let pages = attachment.pages { parts.append(L("ask.attach.pages", pages)) }
            if attachment.truncated == true { parts.append(L("ask.attach.truncated")) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    /// Attachment images are data URLs; each is decoded once and kept while the app runs.
    @MainActor private static let imageCache = NSCache<NSString, NSImage>()

    @MainActor static func thumbnail(id: String, dataURL: String) -> NSImage? {
        if let cached = imageCache.object(forKey: id as NSString) { return cached }
        guard let image = AskImage.decode(dataURL) else { return nil }
        imageCache.setObject(image, forKey: id as NSString)
        return image
    }
}

struct AskAttachmentChip: View {
    let item: AskContextItem
    var thumbnail: NSImage?
    var caption: String?
    var onTap: (() -> Void)?
    var onRemove: (() -> Void)?
    @State private var hovering = false

    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 7) {
            leading
            Text(item.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(StudioTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
                .fixedSize()
            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .frame(width: 18, height: 18)
                        .background(hovering ? AskTheme.hoverFill : Color.clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L("ask.remove"))
                .accessibilityLabel(L("ask.remove") + " " + item.title)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, onRemove == nil ? 10 : 5)
        .frame(height: Self.height)
        .background(AskTheme.hoverFill, in: Capsule())
        .overlay(Capsule().strokeBorder(AskTheme.border, lineWidth: 0.5))
        .contentShape(Capsule())
        .onTapGesture { onTap?() }
        .onHover { hovering = $0 }
        .help(item.detail ?? item.title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title)
    }

    @ViewBuilder private var leading: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(AskTheme.border, lineWidth: 0.5))
        } else if let bundle = item.appBundleID, let icon = AskContextChips.appIcon(bundle) {
            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
        } else {
            Image(systemName: item.systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(AskTheme.accent)
                .frame(width: 22, height: 22)
                .background(AskTheme.accent.opacity(0.15), in: Circle())
        }
    }
}

/// A skill or MCP server chosen with a slash command for the next message.
struct AskChosenTool: Equatable, Identifiable {
    enum Kind: String { case skill, mcpServer }
    var kind: Kind
    var name: String

    var id: String { kind.rawValue + ":" + name }
    var symbol: String { kind == .skill ? "bolt" : "powerplug" }
    var caption: String { L(kind == .skill ? "ask.command.chip.skill" : "ask.command.chip.mcp") }
}
