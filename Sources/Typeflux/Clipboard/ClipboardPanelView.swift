import AppKit
import SwiftUI

/// The clipboard panel: search, type tabs, the grouped list with an optional preview pane, and
/// an action footer.
struct ClipboardPanelView: View {
    /// Width of the list; the preview pane adds `ClipboardPreviewPane.width` to its right.
    static let width: CGFloat = 640
    static let height: CGFloat = 560

    static func size(showsPreview: Bool) -> NSSize {
        NSSize(width: width + (showsPreview ? ClipboardPreviewPane.width : 0), height: height)
    }

    private static let listSpace = "ClipboardPanelView.list"

    @ObservedObject var model: ClipboardPanelModel
    let focusRequest: Int
    /// Read from settings each time the panel opens.
    var interfaceStyle: InterfaceStyle = .liquidGlass
    @ObservedObject var layout = ClipboardPanelLayout()
    @FocusState private var searchFocused: Bool
    @Namespace private var tabNamespace
    @State private var hoveredIndex: Int?
    @State private var showingNumberHints = false
    @State private var rowFrames = ClipboardRowFrames()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.askGlassMaterialOverride) private var materialOverride

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.6)
            HStack(spacing: 0) {
                list.frame(width: Self.width)
                if model.showsPreview || previewWidth > 0 {
                    preview
                }
            }
            Divider().opacity(0.6)
            footer
        }
        .frame(width: viewportWidth, height: Self.height)
        .foregroundStyle(StudioTheme.textPrimary)
        .background(AskGlassBackground(
            material: materialOverride ?? AskGlassMaterial.resolve(reduceTransparency: reduceTransparency,
                                                                   style: interfaceStyle),
            corner: 16, opaqueFill: AskTheme.launcherSurface
        ))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AskTheme.floatingBorder, lineWidth: contrast == .increased ? 1 : 0.5)
        )
        .overlay(alignment: .bottom) { noticeToast }
        .overlay { if model.editingText != nil { ClipboardEditBeforePaste(model: model) } }
        .overlay(alignment: .bottom) {
            if let pending = model.pendingConfirmation {
                ClipboardConfirmationBar(
                    message: pending.message, onCancel: model.cancelPending, onConfirm: model.confirmPending
                )
            }
        }
        .environment(\.askLauncherNumberHints, showingNumberHints)
        .environment(\.interfaceStyle, interfaceStyle)
        .background(AskLauncherCommandMonitor { showingNumberHints = $0 })
        .onAppear { searchFocused = true }
        .onChange(of: focusRequest) { _ in searchFocused = true }
        .onChange(of: model.editingText == nil) { closed in
            if closed { searchFocused = true }
        }
    }

    private var viewportWidth: CGFloat {
        layout.width ?? Self.size(showsPreview: model.showsPreview).width
    }

    private var previewWidth: CGFloat { max(0, viewportWidth - Self.width) }

    /// Keep the content mounted during collapse and reveal it from the list's right edge.
    private var preview: some View {
        let entry = model.previewEntry ?? model.selectedEntry
        return ClipboardPreviewPane(entry: entry, isMissing: entry.map(model.isMarkedMissing) ?? false)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.5)
            }
            .opacity(min(1, previewWidth / ClipboardPreviewPane.width))
            .frame(width: previewWidth, alignment: .leading)
            .clipped()
            .allowsHitTesting(model.showsPreview)
            .accessibilityHidden(!model.showsPreview)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(StudioTheme.textSecondary)
            if let app = model.appFilter {
                ClipboardAppFilterChip(app: app) {
                    model.setAppFilter(nil)
                    searchFocused = true
                }
            }
            TextField(L("clipboard.search.placeholder"), text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($searchFocused)
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(L("clipboard.search.clear"))
            }
            categoryTabs
            ClipboardPanelToolbar(model: model)
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 54)
    }

    private var categoryTabs: some View {
        HStack(spacing: 0) {
            ForEach(ClipboardCategory.allCases) { category in
                let selected = model.category == category
                Text(category.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.1))
                                .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                                .matchedGeometryEffect(id: "tab", in: tabNamespace)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { model.category = category }
                        searchFocused = true
                    }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: model.category)
        // The search field shrinks before the tab titles wrap.
        .fixedSize()
    }

    // MARK: - List

    private var list: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.rows) { row in
                            if let header = row.header {
                                Text(header.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(StudioTheme.textSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                            }
                            rowView(row)
                                .id(row.entry.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .coordinateSpace(name: Self.listSpace)
                .overlay { if model.visibleEntries.isEmpty { emptyState } }
                .onPreferenceChange(ClipboardRowFramesKey.self) { frames in
                    rowFrames.frames = frames
                    rowFrames.viewportHeight = geometry.size.height
                    if let first = ClipboardPanelModel.firstFullyVisibleIndex(
                        frames: frames, viewportHeight: geometry.size.height
                    ) {
                        model.updateFirstVisibleIndex(first)
                    }
                }
                .onChange(of: model.selectedIndex) { index in
                    reveal(index, proxy: proxy)
                }
                .onChange(of: model.scrollToTopRequest) { _ in
                    if let first = model.rows.first { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
        }
    }

    private func rowView(_ row: ClipboardPanelModel.Row) -> some View {
        let index = row.index
        return ClipboardPanelRow(
            entry: row.entry,
            index: index,
            isSelected: index == model.selectedIndex,
            isHovered: hoveredIndex == index,
            isMissing: model.isMarkedMissing(row.entry),
            number: showingNumberHints ? model.shortcutNumber(at: index) : nil,
            onClick: { model.click(index: index, clickCount: $0) },
            onPerform: { model.perform($0, at: index) },
            onHover: { hovering in
                if hovering {
                    hoveredIndex = index
                } else if hoveredIndex == index {
                    hoveredIndex = nil
                }
            }
        )
        .equatable()
        .background(GeometryReader { proxy in
            let frame = proxy.frame(in: .named(Self.listSpace))
            Color.clear.preference(key: ClipboardRowFramesKey.self, value: [index: frame.minY ... frame.maxY])
        })
    }

    /// Scrolls only when the row is not already fully on screen, without animation.
    private func reveal(_ index: Int, proxy: ScrollViewProxy) {
        guard model.visibleEntries.indices.contains(index) else { return }
        if let frame = rowFrames.frames[index], frame.lowerBound >= 0, frame.upperBound <= rowFrames.viewportHeight {
            return
        }
        let anchor: UnitPoint = index >= model.firstVisibleIndex ? .bottom : .top
        proxy.scrollTo(model.visibleEntries[index].id, anchor: anchor)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .light))
            Text(model.query.isEmpty ? L("clipboard.empty") : L("clipboard.search.noResults", model.query))
                .font(.system(size: 12.5))
        }
        .foregroundStyle(StudioTheme.textSecondary)
    }

}

// MARK: - Footer

extension ClipboardPanelView {
    private var footer: some View {
        HStack(spacing: 2) {
            Text(L("clipboard.footer.count", model.visibleEntries.count))
                .font(.system(size: 11.5))
                .foregroundStyle(StudioTheme.textSecondary)
            if model.isRecordingPaused {
                ClipboardPausedChip { model.send(.togglePause) }
            }
            Spacer()
            if let entry = model.selectedEntry {
                if entry.kind.isTextual == false {
                    footerButton(.quickLook, entry: entry)
                }
                footerButton(.togglePin, entry: entry)
                Divider().frame(height: 14).padding(.horizontal, 4)
                footerButton(.paste, entry: entry, primary: true)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 40)
    }

    private func footerButton(_ action: ClipboardEntryAction, entry: ClipboardEntry, primary: Bool = false) -> some View {
        Button {
            model.perform(action)
        } label: {
            HStack(spacing: 6) {
                Text(action.title(for: entry))
                if let shortcut = action.shortcutLabel {
                    ClipboardKeycap(text: shortcut)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(primary ? StudioTheme.textPrimary : StudioTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.isEnabled(action, for: entry))
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
                .padding(.bottom, 52)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

/// A small rounded key label such as `⌘P`.
struct ClipboardKeycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(StudioTheme.textSecondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.1)))
    }
}
