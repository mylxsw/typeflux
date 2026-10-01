import AppKit
import SwiftUI

/// One piece of context riding with a question: the screenshot, the source
/// app, a text selection or memory. The composer draws each as a round icon
/// chip; the words live in a hover card, so a long window title can no longer
/// push the whole group into an overflow menu.
struct AskContextItem: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case screenshot, source, selection, memory
    }

    enum Badge: Equatable {
        /// A small count in the top corner, such as selected lines.
        case count(Int)
        /// A small app icon in the bottom corner, looked up by bundle identifier.
        case app(String)
    }

    var kind: Kind
    var systemImage: String
    /// Draws this app's icon in place of `systemImage` when it can be resolved.
    var appBundleID: String?
    var style: AskChip.Style
    var title: String
    var detail: String?
    var hint: String?
    var badge: Badge?
    var removable = false

    var id: String { kind.rawValue }

    /// Screenshot and source decide whether the question carries what is on
    /// screen, so they never collapse into "+N".
    var alwaysVisible: Bool { kind == .screenshot || kind == .source }
}

/// The screenshot chip's state, resolved by the composer from the model.
enum AskScreenshotState: Equatable {
    case off
    case attached
    case unavailable(reason: String)
    case failed(permission: Bool, message: String)
}

enum AskContextChips {
    static let chipSize: CGFloat = AskMetrics.composerControlHeight
    static let spacing: CGFloat = 4
    static let hoverDelay: UInt64 = 150_000_000
    static let cardWidth: CGFloat = 240
    static let selectionPreviewLength = 60

    /// `AskContextCapture` joins the app name and window title with " — ".
    static func sourceParts(_ source: String) -> (app: String, window: String?) {
        guard let range = source.range(of: " — ") else { return (source, nil) }
        let window = String(source[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (String(source[..<range.lowerBound]), window.isEmpty ? nil : window)
    }

    static func selectionPreview(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > selectionPreviewLength else { return flat }
        return String(flat.prefix(selectionPreviewLength)) + "…"
    }

    /// Items in display order: screenshot, source, selection, memory.
    static func items(screenshot: AskScreenshotState, source: String?, sourceBundleID: String?,
                      selection: String?, selectionOff: Bool = false, memory: AskMemory?, memoryOff: Bool = false,
                      memoryPinned: Bool) -> [AskContextItem] {
        var items = [screenshotItem(screenshot)]
        if let source, !source.isEmpty {
            let parts = sourceParts(source)
            items.append(AskContextItem(kind: .source, systemImage: "macwindow", appBundleID: sourceBundleID,
                                        style: .neutral, title: parts.app, detail: parts.window))
        }
        if let selection, !selection.isEmpty {
            // A toggle like memory: switched off it stays as a grey chip, so the
            // selected text can be switched back on for this question.
            let lines = AskPresentation.lineCount(selection)
            items.append(AskContextItem(
                kind: .selection, systemImage: "text.alignleft", style: selectionOff ? .neutral : .active,
                title: L("ask.selection.lines", lines),
                detail: "“" + selectionPreview(selection) + "”",
                hint: L(selectionOff ? "ask.context.selection.onHint" : "ask.context.selection.offHint"),
                badge: selectionOff ? nil : .count(lines)
            ))
        }
        if memoryPinned {
            items.append(AskContextItem(kind: .memory, systemImage: "brain", style: .neutral,
                                        title: L("ask.memory"), detail: L("ask.memory.pinned")))
        } else if let memory, !memory.isEmpty {
            // A toggle, not a removal: switched off it stays as a grey chip, so
            // it can be switched back on.
            let app = memory.app.flatMap { $0.excerpts.isEmpty ? nil : $0.id }
            items.append(AskContextItem(kind: .memory, systemImage: "brain", style: memoryOff ? .neutral : .active,
                                        title: memory.chipTitle, detail: L("ask.memory.help"),
                                        hint: L(memoryOff ? "ask.context.memory.onHint" : "ask.context.memory.offHint"),
                                        badge: app.map(AskContextItem.Badge.app)))
        }
        return items
    }

    private static func screenshotItem(_ state: AskScreenshotState) -> AskContextItem {
        switch state {
        case .off:
            return AskContextItem(kind: .screenshot, systemImage: "camera.viewfinder", style: .neutral,
                                  title: L("ask.screenshot"), hint: L("ask.context.screenshot.offHint"))
        case .attached:
            return AskContextItem(kind: .screenshot, systemImage: "camera.viewfinder", style: .active,
                                  title: L("ask.context.screenshot.attached"), hint: L("ask.context.previewHint"),
                                  removable: true)
        case let .unavailable(reason):
            return AskContextItem(kind: .screenshot, systemImage: "camera.viewfinder", style: .unavailable,
                                  title: L("ask.screenshot.unavailable"), detail: reason)
        case let .failed(permission, message):
            return AskContextItem(kind: .screenshot, systemImage: "exclamationmark.triangle.fill", style: .warning,
                                  title: L(permission ? "ask.capture.settings" : "ask.capture.retry"),
                                  detail: message)
        }
    }

    /// Layouts to try from widest to narrowest: everything, then the rightmost
    /// collapsible items folded one at a time into "+N".
    static func layouts(_ items: [AskContextItem]) -> [(shown: [AskContextItem], hidden: [AskContextItem])] {
        var result = [(shown: items, hidden: [AskContextItem]())]
        var shown = items
        var hidden: [AskContextItem] = []
        while let index = shown.lastIndex(where: { !$0.alwaysVisible }) {
            hidden.insert(shown.remove(at: index), at: 0)
            result.append((shown, hidden))
        }
        return result
    }

    /// macOS draws an app's tile on 824 of its 1024pt canvas; the rest is margin
    /// for the shadow. Scaling by the inverse makes the tile fill a given side.
    static let appIconTileFraction: CGFloat = 824.0 / 1024.0
    /// An app tile is usually bright and fully opaque, so at the full chip size
    /// it reads larger than the tinted chips beside it. It is drawn a little
    /// smaller to match them optically, still without a margin inside its edge.
    static let appTileSize: CGFloat = 24
    static let appTileCorner: CGFloat = 6

    /// Side of the app icon image whose tile exactly covers `tile`.
    static func appIconSide(tile: CGFloat) -> CGFloat {
        (tile / appIconTileFraction).rounded(.up)
    }

    /// App icons by bundle identifier; nil when the app cannot be found.
    @MainActor static func appIcon(_ bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = icon
        return icon
    }

    @MainActor private static var iconCache: [String: NSImage] = [:]
}

/// A round context chip. Colour carries the state; after a short hover a card
/// above it gives the name, the details and what a click does. Removal is a
/// corner badge that appears on hover.
struct AskIconChip: View {
    let item: AskContextItem
    var action: (() -> Void)?
    var onRemove: (() -> Void)?
    @State private var hovering = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var anchor = AskHoverAnchor.Holder()
    @State private var cardID = UUID()

    var body: some View {
        Button {
            dismissCard()
            action?()
        } label: {
            AskIconChipFace(item: item, hovering: hovering)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if hovering, item.removable, let onRemove {
                Button {
                    dismissCard()
                    onRemove()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 14, height: 14)
                        .background(Color(nsColor: .systemGray), in: Circle())
                        .overlay(Circle().strokeBorder(AskTheme.composerSurface, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                // Mostly inside the chip, so reaching for it never ends the hover.
                .offset(x: 1, y: -1)
                .accessibilityHidden(true)
            }
        }
        .onHover(perform: hover)
        .onDisappear(perform: dismissCard)
        // The card is a click-through panel, not a popover: a popover swallowed
        // the click meant for the chip. See AskHoverCardPresenter.
        .background(AskHoverAnchor(holder: anchor))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.title)
        .accessibilityHint(item.detail ?? item.hint ?? "")
        .accessibilityAction { action?() }
        .accessibilityAction(named: L("ask.remove")) { if item.removable { onRemove?() } }
    }

    private func hover(_ inside: Bool) {
        hovering = inside
        hoverTask?.cancel()
        guard inside else { AskHoverCardPresenter.shared.hide(owner: cardID); return }
        hoverTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: AskContextChips.hoverDelay)
            guard !Task.isCancelled, hovering, let view = anchor.view else { return }
            AskHoverCardPresenter.shared.show(AskContextCard(items: [item]), owner: cardID, anchor: view)
        }
    }

    private func dismissCard() {
        hoverTask?.cancel()
        AskHoverCardPresenter.shared.hide(owner: cardID)
    }
}

struct AskIconChipFace: View {
    let item: AskContextItem
    var hovering = false

    private var shape: Circle { Circle() }
    private var appImage: NSImage? {
        guard let bundleID = item.appBundleID else { return nil }
        return AskContextChips.appIcon(bundleID)
    }

    var body: some View {
        icon
            .frame(width: AskContextChips.chipSize, height: AskContextChips.chipSize)
            // Borderless like the other footer controls: only state and hover fill the circle.
            // An app icon is its own tile, so it only takes the hover wash.
            .background(appImage == nil ? fill : (hovering ? AskTheme.hoverFill : .clear), in: shape)
            .overlay(alignment: .topTrailing) {
                if case let .count(value) = item.badge {
                    Text(verbatim: value > 99 ? "99+" : String(value))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(AskTheme.accent, in: Capsule())
                        .overlay(Capsule().strokeBorder(AskTheme.composerSurface, lineWidth: 1.5))
                        .offset(x: 2, y: -3)
                        .opacity(hovering && item.removable ? 0 : 1)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if case let .app(bundleID) = item.badge, let image = AskContextChips.appIcon(bundleID) {
                    Image(nsImage: image).resizable().frame(width: 13, height: 13).offset(x: 1, y: 1)
                }
            }
            .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        if let image = appImage {
            Image(nsImage: image).resizable().interpolation(.high)
                .frame(width: AskContextChips.appIconSide(tile: AskContextChips.appTileSize),
                       height: AskContextChips.appIconSide(tile: AskContextChips.appTileSize))
                .frame(width: AskContextChips.appTileSize, height: AskContextChips.appTileSize)
                .clipShape(RoundedRectangle(cornerRadius: AskContextChips.appTileCorner, style: .continuous))
                .opacity(hovering ? 0.85 : 1)
        } else {
            ZStack {
                Image(systemName: item.systemImage).font(.system(size: 15, weight: .regular))
                if item.style == .unavailable {
                    Rectangle().frame(width: 20, height: 1.5).rotationEffect(.degrees(-45))
                }
            }
            .foregroundStyle(foreground)
        }
    }

    private var foreground: Color {
        switch item.style {
        case .active: return AskTheme.accentText
        case .warning: return StudioTheme.warning
        case .unavailable: return StudioTheme.textTertiary
        case .neutral: return StudioTheme.textSecondary
        }
    }

    private var fill: Color { Self.fillColor(item.style, hovering: hovering) }

    /// Translucent washes rather than the opaque soft tokens, so the chips sit on the
    /// launcher's glass as well as on the workspace card.
    static func fillColor(_ style: AskChip.Style, hovering: Bool) -> Color {
        switch style {
        case .active: return AskTheme.accent.opacity(hovering ? 0.30 : 0.20)
        case .warning: return StudioTheme.warning.opacity(hovering ? 0.26 : 0.18)
        case .neutral, .unavailable: return hovering ? AskTheme.hoverFill : .clear
        }
    }
}

/// Collapsed items. Hover lists them; a click opens them as removable rows.
struct AskOverflowChip: View {
    let hidden: [AskContextItem]
    var onRemove: (AskContextItem.Kind) -> Void
    @State private var hovering = false
    @State private var showingList = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var anchor = AskHoverAnchor.Holder()
    @State private var cardID = UUID()

    var body: some View {
        Button {
            dismissCard()
            showingList = true
        } label: {
            Text(verbatim: "+\(hidden.count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: AskContextChips.chipSize)
                .background(hovering ? AskTheme.hoverFill : AskTheme.hoverFill.opacity(0.6), in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            hoverTask?.cancel()
            guard inside else { AskHoverCardPresenter.shared.hide(owner: cardID); return }
            hoverTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: AskContextChips.hoverDelay)
                guard !Task.isCancelled, hovering, !showingList, let view = anchor.view else { return }
                AskHoverCardPresenter.shared.show(AskContextCard(items: hidden), owner: cardID, anchor: view)
            }
        }
        .onDisappear(perform: dismissCard)
        .background(AskHoverAnchor(holder: anchor))
        .popover(isPresented: $showingList, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(hidden) { item in
                    HStack(alignment: .top, spacing: 10) {
                        AskIconChipFace(item: item)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 12, weight: .semibold))
                            if let detail = item.detail {
                                Text(detail).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
                                    .lineLimit(3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if item.removable {
                            Button(L("ask.remove")) { onRemove(item.kind) }
                                .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 320)
        }
        .accessibilityLabel(L("ask.context.more", hidden.count))
        .accessibilityHint(hidden.map(\.title).joined(separator: ", "))
    }

    private func dismissCard() {
        hoverTask?.cancel()
        AskHoverCardPresenter.shared.hide(owner: cardID)
    }
}

/// The hover card: name, details, then what a click does.
struct AskContextCard: View {
    let items: [AskContextItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    if let detail = item.detail {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
                            .lineLimit(3)
                    }
                    if let hint = item.hint {
                        Text(hint).font(.system(size: 11, weight: .semibold)).foregroundStyle(AskTheme.accentText)
                            .padding(.top, 2)
                    }
                }
            }
        }
        .frame(width: AskContextChips.cardWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
    }
}
