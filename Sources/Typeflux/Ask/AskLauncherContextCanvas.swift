import AppKit
import SwiftUI

/// The launcher's results area while the question carries context
/// (`AskLauncherContextHome`): a headline under a small orb, a preview to check
/// what rides along, and the questions most often asked about it. ↓ enters the
/// starters, ↑ on the first returns to the editor, Return or ⌘1…⌘4 send one,
/// Tab or → put it in the editor to change it first.
struct AskLauncherContextCanvas: View {
    var content: AskLauncherContextHome.Content
    var attachments: [AskAttachment]
    @Binding var highlighted: Int?
    var palette: AskOrbPalette = .brand
    var viewportHeight: CGFloat
    var onSend: (AskLauncherContextHome.Starter) -> Void
    var onFill: (AskLauncherContextHome.Starter) -> Void
    var onRemove: (() -> Void)?

    @State private var pointer = AskSearchPointer(position: NSEvent.mouseLocation)

    private var layout: AskLauncherContextHome.Layout { AskLauncherContextHome.layout(viewport: viewportHeight) }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AskTheme.launcherSeparator).frame(height: 1).padding(.horizontal, 12)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if content.subject == .pending {
                        AskLauncherContextPlaceholder(compact: layout.compactPreview)
                    } else if !attachments.isEmpty {
                        AskLauncherContextPreview(attachments: attachments, compact: layout.compactPreview,
                                                  onRemove: onRemove)
                    }
                    if !content.starters.isEmpty { starters }
                }
                .padding(AskLauncherSuggestions.listPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: viewportHeight, alignment: .top)
        .background(AskLauncherHomeKeyMonitor { key in handle(key) })
        .onChange(of: content.starters.count) { count in
            if let index = highlighted, index >= count { highlighted = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if layout.showsOrb {
                AskConversationOrb(size: 34, palette: palette)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(content.title).font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                Text(content.subtitle).font(.system(size: 12))
                    .foregroundStyle(AskTheme.launcherMetaText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AskLauncherSuggestions.contentInset)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: AskLauncherSuggestions.rowSpacing) {
            HStack {
                Text(L("ask.launcher.context.section")).foregroundStyle(AskTheme.launcherMetaText)
                Spacer(minLength: 0)
                Text(L("ask.launcher.context.fillHint")).foregroundStyle(AskTheme.launcherMetaText)
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, AskLauncherSuggestions.contentInset)
            .padding(.bottom, AskLauncherSuggestions.headerBottomGap)
            .frame(height: AskLauncherSuggestions.headerHeight, alignment: .bottomLeading)
            ForEach(Array(content.starters.enumerated()), id: \.element.id) { index, starter in
                row(starter, index: index)
            }
        }
    }

    private func row(_ starter: AskLauncherContextHome.Starter, index: Int) -> some View {
        let selected = highlighted == index
        return Button { onSend(starter) } label: {
            HStack(spacing: 12) {
                Image(systemName: starter.symbol).font(.system(size: 12.5))
                    .foregroundStyle(AskLauncherSuggestions.tint(starter.tint))
                    .frame(width: 28, height: 28)
                    .background(AskLauncherSuggestions.tileFill(starter.tint),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(starter.title).font(.system(size: 13.5))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(starter.detail).font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, AskLauncherSuggestions.contentInset)
            .frame(height: AskLauncherSuggestions.rowHeight)
            .background(selected ? AskTheme.launcherSelection : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(AskTheme.launcherSelectionEdge, lineWidth: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(AskLauncherNumberBadge(number: index + 1))
        .onContinuousHover { phase in
            if case .active = phase, pointer.moved(to: NSEvent.mouseLocation) { highlighted = index }
        }
        .accessibilityLabel(starter.title)
        .accessibilityHint(starter.detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func handle(_ key: AskLauncherHomeKeyMonitor.Key) -> Bool {
        let starters = content.starters
        guard !starters.isEmpty else { return false }
        switch key {
        case let .vertical(delta):
            // ↑ in the editor belongs to the input history.
            if delta < 0, highlighted == nil { return false }
            highlighted = AskLauncherContextHome.move(highlighted, by: delta, count: starters.count)
            return true
        case let .number(number):
            guard starters.indices.contains(number - 1) else { return false }
            onSend(starters[number - 1])
            return true
        case .horizontal(1), .tab:
            guard let index = highlighted, starters.indices.contains(index) else { return false }
            onFill(starters[index])
            return true
        case .horizontal:
            return false
        }
    }
}

/// A larger look at what rides with the question than the strip's chips give.
struct AskLauncherContextPreview: View {
    var attachments: [AskAttachment]
    var compact: Bool
    var onRemove: (() -> Void)?

    private var first: AskAttachment? { attachments.first }

    var body: some View {
        HStack(spacing: 14) {
            thumbnail
                .frame(width: compact ? 72 : 150, height: compact ? 45 : 94)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(AskTheme.launcherChipEdge, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title(attachments)).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                if let detail = Self.detail(attachments) {
                    Text(detail).font(.system(size: 11.5))
                        .foregroundStyle(AskTheme.launcherMetaText)
                        .lineLimit(1)
                }
                if !compact, let onRemove {
                    Button(action: onRemove) {
                        Label(L("ask.remove"), systemImage: "xmark").font(.system(size: 11.5))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(AskTheme.launcherChipFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AskTheme.launcherChipEdge))
        .padding(.horizontal, AskLauncherSuggestions.contentInset)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = attachments.first(where: { $0.kind == .image })?.image {
            AskContextImage(source: image) { picture in
                if let picture {
                    Image(nsImage: picture).resizable().scaledToFill()
                } else {
                    symbolTile(Self.symbol(for: .image))
                }
            }
        } else {
            symbolTile(Self.symbol(for: first?.kind))
        }
    }

    private func symbolTile(_ symbol: String) -> some View {
        ZStack {
            AskTheme.launcherTile
            Image(systemName: symbol).font(.system(size: compact ? 16 : 28))
                .foregroundStyle(StudioTheme.textSecondary)
        }
    }

    /// The tile for an item without a picture to show.
    static func symbol(for kind: AskAttachment.Kind?) -> String {
        switch kind {
        case .image: return "photo"
        case .folder: return "folder.fill"
        case .file, nil: return "doc.text.fill"
        }
    }

    /// "Screenshot", "Report.pdf", "Report.pdf + 2 more".
    static func title(_ attachments: [AskAttachment]) -> String {
        guard let first = attachments.first else { return "" }
        if attachments.allSatisfy({ $0.screenshot == true }) { return L("screenshot.ask.attachmentName") }
        return attachments.count > 1 ? L("ask.launcher.context.preview.more", first.name, attachments.count - 1)
            : first.name
    }

    /// Pages and size for one item; the count of pieces for a long screenshot.
    static func detail(_ attachments: [AskAttachment]) -> String? {
        if attachments.count > 1, attachments.allSatisfy({ $0.screenshot == true }) {
            return L("ask.launcher.context.preview.pieces", attachments.count)
        }
        guard attachments.count == 1, let item = attachments.first else { return nil }
        var parts: [String] = []
        if let pages = item.pages { parts.append(L("ask.launcher.context.preview.pages", pages)) }
        if item.kind == .folder, let path = item.path {
            parts.append((path as NSString).abbreviatingWithTildeInPath)
        } else if let bytes = item.byteSize, item.screenshot != true {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The preview's shape while attachments are read, so nothing moves when they arrive.
private struct AskLauncherContextPlaceholder: View {
    var compact: Bool

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(AskTheme.launcherTile)
                .frame(width: compact ? 72 : 150, height: compact ? 45 : 94)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(AskTheme.launcherTile).frame(width: 140, height: 11)
                RoundedRectangle(cornerRadius: 4).fill(AskTheme.launcherTile).frame(width: 90, height: 9)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(AskTheme.launcherChipFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, AskLauncherSuggestions.contentInset)
        .accessibilityHidden(true)
    }
}
