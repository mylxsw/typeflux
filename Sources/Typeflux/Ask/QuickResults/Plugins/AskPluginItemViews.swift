import AppKit
import SwiftUI
import TypefluxMediaProtocol

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
    @Environment(\.colorScheme) private var colorScheme

    private var filled: Bool {
        item.valid && selected && emphasized
    }

    private var opensLibrary: Bool {
        item.id == AskNotesPlugin.openNotesItemID || item.id == AskTranslatePlugin.openAllItem
    }

    /// Content-match excerpts belong in the file preview, not the result list.
    static func showsExcerpt(_ item: AskPluginItem) -> Bool {
        item.excerpt != nil && item.fileHit?.evidence == nil
    }

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 11) {
                AskPluginItemIcon(icon: item.icon, symbol: symbol, filled: filled,
                                  revision: item.fileHit?.modified)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                            .foregroundStyle(item.valid ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                        if let badge = item.badge { ModelUsageBadge(text: badge) }
                    }
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle).font(.system(size: AskTheme.launcherResultDetailSize)).lineLimit(1)
                            .foregroundStyle(AskTheme.launcherResultDetail)
                    }
                    if Self.showsExcerpt(item), let excerpt = item.excerpt {
                        Text(excerpt).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(AskTheme.launcherResultDetail)
                    }
                }
                // The title keeps its room; a long action ("Open in Visual Studio Code") is cut short instead.
                .layoutPriority(1)
                Spacer(minLength: 8)
                if opensLibrary, !selected {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 13))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                if selected, let action = item.actions.first(where: { $0.shortcut == .enter }) {
                    Text("↩ " + action.title).font(.system(size: AskTheme.launcherResultDetailSize)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(filled ? AskTheme.accentText : AskTheme.launcherResultDetail)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(item.valid && selected && (filled || colorScheme == .light)
                ? AskTheme.launcherSelection : item.valid && selected ? AskTheme.hoverFill : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottom) {
                if opensLibrary {
                    Rectangle().fill(StudioTheme.textTertiary.opacity(0.15)).frame(height: 0.5)
                        .padding(.horizontal, 8)
                }
            }
            .contentShape(Rectangle())
            .overlay {
                if item.valid, selected, filled || colorScheme == .light {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(AskTheme.launcherSelectionEdge, lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!item.valid)
        .accessibilityLabel(item.subtitle.isEmpty ? item.title : item.title + ", " + item.subtitle)
        .accessibilityAddTraits(item.valid && selected ? .isSelected : [])
        .accessibilityIdentifier("ask.plugin.item")
    }
}

/// A row's icon: an SF Symbol, an image file, a file's Finder icon or a type's icon.
struct AskPluginItemIcon: View {
    var icon: AskPluginItem.Icon?
    var symbol: String
    var filled: Bool
    var revision: Date?
    @Environment(\.askIconGeneration) private var generation
    @AppStorage(AskLauncherFeatureIcons.preferenceKey) private var iconStyle: AskLauncherFeatureIcons.Style = .sculpted

    private var iconSize: CGFloat {
        if case .feature = icon { return AskLauncherFeatureIcons.listIconSize }
        return 28
    }

    var body: some View {
        Group {
            if case let .feature(name) = icon, let image = AskLauncherFeatureIcons.image(for: name, style: iconStyle) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(width: iconSize, height: iconSize)
            } else if case let .websiteIcon(url, fallback, application) = icon {
                AskBrowserFaviconView(url: url, fallback: fallback, application: application, symbol: symbol, filled: filled).id(generation)
            } else if case let .application(bundleID) = icon {
                AskNativeIconView(icon: .init(kind: .application, value: bundleID), symbol: symbol).frame(width: 26, height: 26)
            } else if case let .fileIcon(url) = icon {
                AskFileIconView(url: url, thumbnail: false, modified: revision).frame(width: 26, height: 26)
            } else if case let .image(url) = icon {
                AskSmallFileIcon(url: url, symbol: symbol, filled: filled)
            } else if case let .fileType(type) = icon {
                AskNativeIconView(icon: .init(kind: .type, value: type), symbol: symbol).frame(width: 26, height: 26)
            } else {
                Image(systemName: Self.symbolName(icon) ?? symbol).aiSymbolTint(Self.symbolName(icon) ?? symbol)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(filled ? AskTheme.accentText : StudioTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(filled ? Color.clear : AskTheme.hoverFill,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .frame(width: iconSize, height: iconSize)
        .accessibilityHidden(true)
    }

    static func symbolName(_ icon: AskPluginItem.Icon?) -> String? {
        guard case let .symbol(name) = icon, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        else { return nil }
        return name
    }

    /// Synchronous projections never invoke native icon lookup or image decoding.
    static func image(_: AskPluginItem.Icon) -> NSImage? {
        nil
    }
}
