import AppKit
import SwiftUI

/// Where the selected card is, reported by the shelf so the controller can place the preview
/// window above it. `nil` while the card is scrolled out of view.
final class ClipboardShelfLayout: ObservableObject {
    @Published private(set) var selectedCardMidX: CGFloat?

    func setSelectedCardMidX(_ value: CGFloat?) {
        let rounded = value.map { $0.rounded() }
        if rounded != selectedCardMidX { selectedCardMidX = rounded }
    }
}

/// The clipboard as a shelf along the bottom of the screen: search, tabs and app filters on top,
/// one card per entry in a horizontal rail, and a hint bar. Shares `ClipboardPanelModel` with
/// the list panel; only the layout and the arrow keys differ.
struct ClipboardShelfView: View {
    static let height: CGFloat = 348
    /// While the snippet editor or edit-before-paste covers the shelf.
    static let editingHeight: CGFloat = 470
    static let topBarHeight: CGFloat = 52
    static let footerHeight: CGFloat = 28
    static let cornerRadius: CGFloat = 18
    static let cardSpacing: CGFloat = 12

    private static let railSpace = "ClipboardShelfView.rail"
    /// The rail's leading edge, so scrolling back shows the first section title too.
    private static let railStart = "ClipboardShelfView.railStart"

    @ObservedObject var thumbnails = ClipboardThumbnailSession()
    @ObservedObject var model: ClipboardPanelModel
    let focusRequest: Int
    @ObservedObject var focusSignal = ClipboardPanelFocusSignal()
    var interfaceStyle: InterfaceStyle?
    @ObservedObject var layout = ClipboardShelfLayout()
    @Environment(\.interfaceStyle) private var environmentStyle
    @FocusState private var searchFocused: Bool
    @State private var hoveredIndex: Int?
    @State private var showingNumberHints = false
    @State private var cardFrames = ClipboardRowFrames()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.askGlassMaterialOverride) private var materialOverride

    private var effectiveStyle: InterfaceStyle { interfaceStyle ?? environmentStyle }

    var body: some View {
        VStack(spacing: 0) {
            ClipboardShelfTopBar(model: model, thumbnails: thumbnails, searchFocused: $searchFocused)
            rail
            ClipboardShelfFooter(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(StudioTheme.textPrimary)
        .background(AskGlassBackground(
            material: materialOverride ?? AskGlassMaterial.resolve(reduceTransparency: reduceTransparency,
                                                                   style: effectiveStyle),
            corner: Self.cornerRadius, opaqueFill: AskTheme.launcherSurface
        ))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(AskTheme.floatingBorder, lineWidth: contrast == .increased ? 1 : 0.5)
        )
        .overlay(alignment: .bottom) { noticeToast }
        .overlay { if model.editingText != nil { ClipboardEditBeforePaste(model: model) } }
        .overlay { if model.snippetDraft != nil { ClipboardSnippetEditor(model: model) } }
        .overlay(alignment: .bottom) {
            if let pending = model.pendingConfirmation {
                ClipboardConfirmationBar(
                    message: pending.message, onCancel: model.cancelPending, onConfirm: model.confirmPending
                )
                .frame(maxWidth: 640)
            }
        }
        .environment(\.askLauncherNumberHints, showingNumberHints)
        .environment(\.interfaceStyle, effectiveStyle)
        .background(AskLauncherCommandMonitor { showingNumberHints = $0 })
        .onAppear { searchFocused = true }
        .onChange(of: focusRequest) { _ in searchFocused = true }
        .onChange(of: focusSignal.generation) { _ in searchFocused = true }
        .onChange(of: model.snippetDraft == nil) { closed in
            if closed { searchFocused = true }
        }
        .onChange(of: model.editingText == nil) { closed in
            if closed { searchFocused = true }
        }
    }

    // MARK: - Rail

    private var rail: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 0, height: 0).id(Self.railStart)
                        LazyHStack(alignment: .top, spacing: Self.cardSpacing) {
                            ForEach(model.rows) { row in
                                if let header = row.header {
                                    sectionLabel(header.title)
                                }
                                card(row)
                                    .id(row.entry.id)
                            }
                        }
                        // Rotated section titles extend beyond their narrow layout frame.
                        .padding(.leading, 28)
                        .padding(.trailing, 16)
                        // Room for the selected card's lift and shadow.
                        .padding(.top, 10)
                        .padding(.bottom, 14)
                    }
                }
                .coordinateSpace(name: Self.railSpace)
                .overlay { if model.visibleEntries.isEmpty { emptyState } }
                .onPreferenceChange(ClipboardRowFramesKey.self) { frames in
                    cardFrames.frames = frames
                    cardFrames.viewportHeight = geometry.size.width
                    if let first = ClipboardPanelModel.firstFullyVisibleIndex(
                        frames: frames, viewportHeight: geometry.size.width
                    ) {
                        model.updateFirstVisibleIndex(first)
                    }
                    reportSelectedCard()
                }
                .onChange(of: model.selectedIndex) { index in
                    reveal(index, proxy: proxy)
                    reportSelectedCard()
                }
                .onChange(of: model.scrollToTopRequest) { _ in
                    proxy.scrollTo(Self.railStart, anchor: .leading)
                }
            }
        }
    }

    private func card(_ row: ClipboardPanelModel.Row) -> some View {
        let index = row.index
        return ClipboardShelfCard(
            entry: row.entry,
            index: index,
            isSelected: index == model.selectedIndex,
            isHovered: hoveredIndex == index,
            isMissing: model.isMarkedMissing(row.entry),
            number: showingNumberHints ? model.shortcutNumber(at: index) : nil,
            onClick: { model.click(index: index, clickCount: $0) },
            onPerform: { model.perform($0, at: index) },
            onDragEnded: { model.dragEnded(accepted: $0) },
            onHover: { hovering in
                if hovering {
                    hoveredIndex = index
                } else if hoveredIndex == index {
                    hoveredIndex = nil
                }
            }
        )
        .equatable()
        .environment(\.askContextImageAccess, thumbnails.access(for: row.entry))
        .background(GeometryReader { proxy in
            let frame = proxy.frame(in: .named(Self.railSpace))
            Color.clear.preference(key: ClipboardRowFramesKey.self, value: [index: frame.minX ... frame.maxX])
        })
    }

    /// A vertical section title with a hairline, between groups of cards.
    private func sectionLabel(_ title: String) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary)
                .fixedSize()
                .rotationEffect(.degrees(-90))
                .frame(width: 16, height: 16)
                .frame(height: ClipboardShelfCard.height * 0.6)
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 0.5, height: ClipboardShelfCard.height * 0.7)
        }
        .frame(height: ClipboardShelfCard.height, alignment: .top)
        .accessibilityAddTraits(.isHeader)
    }

    /// Scrolls only when the card is not already fully visible.
    private func reveal(_ index: Int, proxy: ScrollViewProxy) {
        guard model.visibleEntries.indices.contains(index) else { return }
        if let frame = cardFrames.frames[index], frame.lowerBound >= 0, frame.upperBound <= cardFrames.viewportHeight {
            return
        }
        let anchor: UnitPoint = index >= model.firstVisibleIndex ? .trailing : .leading
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(model.visibleEntries[index].id, anchor: anchor)
        }
    }

    private func reportSelectedCard() {
        guard let frame = cardFrames.frames[model.selectedIndex],
              frame.upperBound > 0, frame.lowerBound < cardFrames.viewportHeight else {
            layout.setSelectedCardMidX(nil)
            return
        }
        layout.setSelectedCardMidX((frame.lowerBound + frame.upperBound) / 2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 28, weight: .light))
            Text(model.query.isEmpty ? L(model.category.emptyKey) : L("clipboard.search.noResults", model.query))
                .font(.system(size: 12.5))
        }
        .foregroundStyle(StudioTheme.textSecondary)
    }

    @ViewBuilder
    private var noticeToast: some View {
        if let notice = model.notice {
            Text(notice)
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                .padding(.bottom, 40)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

/// Search, tabs, app buttons and tools across the top of the shelf.
struct ClipboardShelfTopBar: View {
    /// App buttons next to the tabs; more apps are reached through a card's menu.
    static let appButtonLimit = 8

    @ObservedObject var model: ClipboardPanelModel
    /// App icons load only with the panel's image access, granted through an entry from that app.
    @ObservedObject var thumbnails: ClipboardThumbnailSession
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 10) {
            searchField
            ClipboardCategoryTabs(model: model) { searchFocused.wrappedValue = true }
            if model.category == .all {
                appButtons
            }
            Spacer(minLength: 8)
            if model.isRecordingPaused {
                ClipboardPausedChip { model.send(.togglePause) }
            }
            ClipboardPanelToolbar(model: model, style: .shelf)
            Button { model.send(.openSettings) } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("clipboard.toolbar.settings"))
            .accessibilityLabel(L("clipboard.toolbar.settings"))
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: ClipboardShelfView.topBarHeight)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(StudioTheme.textSecondary)
            if let app = model.appFilter {
                ClipboardAppFilterChip(app: app) {
                    model.setAppFilter(nil)
                    searchFocused.wrappedValue = true
                }
            }
            TextField(L(model.category.searchPlaceholderKey), text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused(searchFocused)
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    searchFocused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(L("clipboard.search.clear"))
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 320, height: 32)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// One icon per recent source app; clicking filters to it, clicking again shows all apps.
    private var appButtons: some View {
        HStack(spacing: 4) {
            ForEach(model.recentSourceApps(limit: Self.appButtonLimit), id: \.bundleID) { app in
                let selected = model.appFilter?.bundleID == app.bundleID
                Button {
                    model.setAppFilter(selected ? nil : app)
                    searchFocused.wrappedValue = true
                } label: {
                    AskNativeIconImage(icon: ClipboardAppIconProvider.target(bundleID: app.bundleID)) { icon in
                        Group {
                            if let icon {
                                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
                            } else {
                                Image(systemName: "app.dashed").foregroundStyle(StudioTheme.textSecondary)
                            }
                        }
                        .frame(width: 22, height: 22)
                    }
                    .padding(2)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor.opacity(0.22))
                        }
                    }
                    .opacity(model.appFilter == nil || selected ? 1 : 0.55)
                    .contentShape(Rectangle())
                    .environment(\.askContextImageAccess, thumbnails.access(
                        for: model.entries.first { $0.snippet == nil && $0.sourceBundleID == app.bundleID }
                    ))
                }
                .buttonStyle(.plain)
                .help(L("clipboard.action.showOnlyApp", app.name))
                .accessibilityLabel(L("clipboard.action.showOnlyApp", app.name))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Key hints and the item count along the bottom of the shelf.
struct ClipboardShelfFooter: View {
    @ObservedObject var model: ClipboardPanelModel

    var body: some View {
        HStack(spacing: 14) {
            hint("↩", L("clipboard.action.paste"))
            hint("⌘↩", L("clipboard.action.pastePlainText"))
            hint("Space", L("clipboard.shelf.hint.preview"))
            hint("⌘P", L("clipboard.action.pin"))
            hint("⌘⌫", L("clipboard.action.delete"))
            hint("⌘1–9", L("clipboard.shelf.hint.quickPaste"))
            Spacer()
            Text(L("clipboard.footer.count", model.visibleEntries.count))
        }
        .font(.system(size: 11))
        .foregroundStyle(StudioTheme.textSecondary)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(height: ClipboardShelfView.footerHeight)
    }

    private func hint(_ key: String, _ title: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: key).fontWeight(.medium).foregroundStyle(StudioTheme.textPrimary.opacity(0.75))
            Text(title)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The shelf's preview, in its own window above the selected card: the list panel's preview
/// pane at a larger width, on the same glass.
struct ClipboardShelfPreview: View {
    static let size = NSSize(width: 520, height: 380)

    @ObservedObject var model: ClipboardPanelModel
    @ObservedObject var thumbnails: ClipboardThumbnailSession
    var interfaceStyle: InterfaceStyle?
    @Environment(\.interfaceStyle) private var environmentStyle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.askGlassMaterialOverride) private var materialOverride

    var body: some View {
        let entry = model.previewEntry ?? model.selectedEntry
        let style = interfaceStyle ?? environmentStyle
        ClipboardPreviewPane(entry: entry, isMissing: entry.map(model.isMarkedMissing) ?? false,
                             width: Self.size.width)
            .environment(\.askContextImageAccess, thumbnails.access(for: entry))
            .id(entry?.id)
            .frame(width: Self.size.width, height: Self.size.height)
            .foregroundStyle(StudioTheme.textPrimary)
            .background(AskGlassBackground(
                material: materialOverride
                    ?? AskGlassMaterial.resolve(reduceTransparency: reduceTransparency, style: style),
                corner: 16, opaqueFill: AskTheme.launcherSurface
            ))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(AskTheme.floatingBorder, lineWidth: 0.5)
            )
            .environment(\.interfaceStyle, style)
    }
}
