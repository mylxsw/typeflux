import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One row of a result list: icon, title, subtitle, and on the chosen row what
/// Return does ("↩ Copy"). A soft accent wash marks keyboard focus without
/// competing with the title or the list's section heading.
struct AskPluginItemRow: View {
    var item: AskPluginItem
    /// The plugin's symbol, for rows without an icon of their own.
    var symbol: String
    var selected: Bool
    /// The list has the keyboard (not "Ask AI").
    var emphasized: Bool
    var height: CGFloat
    var onPick: () -> Void

    private var filled: Bool {
        selected && emphasized
    }

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 11) {
                AskPluginItemIcon(icon: item.icon, symbol: symbol, filled: filled)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(item.valid ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle).font(.system(size: 11.5)).lineLimit(1)
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                }
                // The title keeps its room; a long action ("Open in Visual Studio Code") is cut short instead.
                .layoutPriority(1)
                Spacer(minLength: 8)
                if selected, let action = item.actions.first(where: { $0.shortcut == .enter }) {
                    Text("↩ " + action.title).font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(filled ? AskTheme.accentText : StudioTheme.textSecondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(filled ? AskTheme.accentSoft : selected ? AskTheme.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.subtitle.isEmpty ? item.title : item.title + ", " + item.subtitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("ask.plugin.item")
    }
}

/// A row's icon: an SF Symbol, an image file, a file's Finder icon or a type's icon.
struct AskPluginItemIcon: View {
    var icon: AskPluginItem.Icon?
    var symbol: String
    var filled: Bool

    var body: some View {
        Group {
            if case let .fileIcon(url) = icon {
                AskFileIconView(url: url, thumbnail: false).frame(width: 26, height: 26)
            } else if let image = icon.flatMap(Self.image) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(width: 26, height: 26)
            } else {
                Image(systemName: Self.symbolName(icon) ?? symbol)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(filled ? AskTheme.accentText : StudioTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(filled ? Color.clear : AskTheme.hoverFill,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    static func symbolName(_ icon: AskPluginItem.Icon?) -> String? {
        guard case let .symbol(name) = icon, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        else { return nil }
        return name
    }

    private static let cache = NSCache<NSString, NSImage>()

    /// The image for a file icon; nil for symbols and for files that are not images.
    static func image(_ icon: AskPluginItem.Icon) -> NSImage? {
        let key: String
        switch icon {
        case .symbol: return nil
        case let .image(url): key = "image:" + url.path
        case let .fileIcon(url): key = "file:" + url.path
        case let .fileType(type): key = "type:" + type
        }
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        let image: NSImage? = switch icon {
        case .symbol: nil
        case let .image(url): NSImage(contentsOf: url)
        case let .fileIcon(url):
            FileManager.default.fileExists(atPath: url.path) ? NSWorkspace.shared.icon(forFile: url.path) : nil
        case let .fileType(type): UTType(type).map { NSWorkspace.shared.icon(for: $0) }
        }
        if let image {
            cache.setObject(image, forKey: key as NSString)
        }
        return image
    }
}
