import AppKit
import SwiftUI

/// The content that rides with the next message, shown above the editor: one
/// labelled capsule per item, each with its own remove button. The footer's
/// round toggles are the switches; this strip only shows what is actually
/// sent, so it never repeats a lit toggle in words.
enum AskAttachmentStrip {
    /// The visible inventory follows the outgoing request. Memory remains a
    /// footer preference; pending and failed screenshots stay visible here.
    static func contentItems(draft: AskDraft, screenshotState: AskScreenshotState,
                             capturing: Bool = false) -> [AskContextItem] {
        var result: [AskContextItem] = []
        if let source = draft.sentSource, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parts = AskContextChips.sourceParts(source)
            result.append(AskContextItem(kind: .source, systemImage: "app", appBundleID: draft.sourceBundleID,
                                         style: .neutral, title: parts.app, detail: parts.window,
                                         hint: L("ask.context.source.metadataOnly"), removable: true))
        }
        if let selection = draft.sentSelection, !selection.isEmpty {
            let source = draft.source.map { AskContextChips.sourceParts($0).app }
            result.append(AskContextItem(kind: .selection, systemImage: "text.alignleft", style: .neutral,
                                         title: "“" + AskContextChips.selectionPreview(selection) + "”",
                                         detail: selection, badge: .count(AskPresentation.lineCount(selection)),
                                         removable: true, sourceAppName: source,
                                         sourceAppBundleID: draft.sourceBundleID))
        }
        guard draft.includeScreenshot else { return result }
        if capturing {
            result.append(AskContextItem(kind: .screenshot, systemImage: "camera.viewfinder", style: .neutral,
                                         title: L("ask.context.screen.capturing"), removable: true))
            return result
        }
        switch screenshotState {
        case .off: break
        case .attached:
            if draft.screenshot != nil {
                result.append(AskContextItem(kind: .screenshot, systemImage: "display", style: .neutral,
                                             title: L("ask.context.screen.full"), detail: L("ask.context.screen.scope"),
                                             removable: true))
            }
        case let .failed(permission, message):
            result.append(AskContextItem(kind: .screenshot, systemImage: "exclamationmark.triangle", style: .warning,
                                         title: L("ask.context.screen.failed"), detail: message,
                                         hint: L(permission ? "ask.context.screen.grant" : "ask.context.screen.retry"),
                                         removable: true))
        case let .unavailable(reason):
            result.append(AskContextItem(kind: .screenshot, systemImage: "exclamationmark.triangle",
                                         style: .unavailable,
                                         title: L("ask.context.screen.failed"), detail: reason, removable: true))
        }
        return result
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
    var draft: Binding<AskDraft>?
    var restored = false
    var capturing = false
    var refreshSource: (() -> Void)?
    var sourceRefreshHelp: String?
    var onScreenshotAction: (() -> Void)?
    var screenshotCapturing = false
    @State private var presented: AskContextItem.Kind?

    var body: some View {
        AskFlowLayout(spacing: 6, itemMaxWidth: 420) {
            ForEach(items) { item in
                AskAttachmentChip(item: item,
                                  thumbnail: item.kind == .screenshot && item.style == .neutral ? screenshot : nil,
                                  caption: selectionCaption(item),
                                  onTap: previewAction(item), onRemove: { presented = nil; onRemove(item.kind) },
                                  sourceMetadata: item.kind == .source, restored: item.kind == .source && restored,
                                  capturing: item.kind == .screenshot && screenshotCapturing,
                                  onRefresh: item.kind == .source && restored ? refreshSource : nil,
                                  refreshHelp: sourceRefreshHelp, refreshDisabled: capturing,
                                  actionLabel: item.style == .warning ? item.hint : nil,
                                  onAction: item.kind == .screenshot ? onScreenshotAction : nil)
                    .popover(isPresented: presentation(for: item.kind), arrowEdge: .top) {
                        details(item)
                    }
                    .disabled(capturing && item.kind != .screenshot)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
            ForEach(attachments) { attachment in
                AskAttachmentChip(item: AskAttachmentStrip.item(attachment),
                                  thumbnail: attachment.image.flatMap {
                                      AskAttachmentStrip.thumbnail(id: attachment.id, dataURL: $0)
                                  },
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

    private func selectionCaption(_ item: AskContextItem) -> String? {
        guard item.kind == .selection, case let .count(lines) = item.badge else { return nil }
        return L(lines == 1 ? "ask.context.selection.singleLine" : "ask.context.selection.lineCount", lines)
    }

    private func previewAction(_ item: AskContextItem) -> (() -> Void)? {
        if item.kind == .screenshot {
            if screenshotCapturing { return nil }
            return item.style == .warning || item.style == .unavailable ? nil : onPreview
        }
        return { presented = item.kind }
    }

    private func presentation(for kind: AskContextItem.Kind) -> Binding<Bool> {
        Binding(get: { presented == kind }, set: { if !$0 { presented = nil } })
    }

    @ViewBuilder private func details(_ item: AskContextItem) -> some View {
        if item.kind == .source, let draft {
            AskSourceContextDetails(draft: draft, restored: restored, capturing: capturing,
                                    refresh: restored ? refreshSource : nil, refreshHelp: sourceRefreshHelp,
                                    onRemove: { presented = nil; onRemove(.source) })
        } else if item.kind == .selection {
            AskSelectedTextDetails(text: draft?.wrappedValue.sentSelection ?? item.detail ?? "",
                                   source: item.sourceAppName, restored: restored,
                                   onRemove: { presented = nil; onRemove(.selection) })
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
    var sourceMetadata = false
    var restored = false
    var capturing = false
    var onRefresh: (() -> Void)?
    var refreshHelp: String?
    var refreshDisabled = false
    var actionLabel: String?
    var onAction: (() -> Void)?
    @State private var hovering = false

    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 4) {
            if let onTap {
                Button(action: onTap) { face }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ask.content.\(item.kind.rawValue).preview")
            } else {
                face
            }
            if let onRefresh {
                AskSourceRefreshButton(help: refreshHelp ?? L("ask.context.refresh.hint"),
                                       disabled: refreshDisabled, action: onRefresh)
            }
            if let actionLabel, let onAction {
                Button(actionLabel, action: onAction)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StudioTheme.warning)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                    .frame(height: 24)
                    .accessibilityIdentifier("ask.content.screenshot.action")
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .frame(width: 24, height: 24)
                        .background(hovering ? AskTheme.hoverFill : Color.clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L("ask.remove"))
                .accessibilityLabel(L("ask.remove") + " " + item.title)
                .accessibilityIdentifier("ask.content.\(item.kind.rawValue).remove")
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, onRemove == nil ? 10 : 5)
        .frame(height: Self.height)
        .background(hovering ? AskTheme.hoverFill : AskTheme.hoverFill.opacity(0.35), in: Capsule())
        .overlay(Capsule().strokeBorder(item.style == .warning || item.style == .unavailable
                    ? StudioTheme.warning.opacity(0.6) : AskTheme.border, lineWidth: 0.5))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .help([item.title, item.detail, item.hint].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title
            + (item.sourceAppName.map { ", " + L("ask.context.selection.source", $0) } ?? ""))
    }

    private var face: some View {
        HStack(spacing: 6) {
            leading
            if restored {
                Text(L("ask.context.source.previous"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
            }
            Text(item.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(item.style == .warning || item.style == .unavailable
                                 ? StudioTheme.warning : StudioTheme.textPrimary)
                .lineLimit(1).truncationMode(sourceMetadata ? .tail : .middle)
                .frame(maxWidth: sourceMetadata ? 160 : 240, alignment: .leading)
                .fixedSize(horizontal: sourceMetadata, vertical: false)
                .layoutPriority(1)
            if sourceMetadata || item.kind == .screenshot && (item.style == .warning || item.style == .unavailable),
               let detail = item.detail {
                Text("· " + detail)
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 180, alignment: .leading)
            }
            if let caption {
                Text(caption).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                    .lineLimit(1).fixedSize()
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var leading: some View {
        if capturing {
            ProgressView().controlSize(.small).frame(width: 22, height: 22)
        } else if let thumbnail {
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
                .foregroundStyle(item.style == .warning || item.style == .unavailable
                                 ? StudioTheme.warning : StudioTheme.textSecondary)
                .frame(width: 22, height: 22)
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
