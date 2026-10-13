import AppKit
import SwiftUI

/// Spotlight chrome around the clipboard list, preview and existing panel actions.
struct ClipboardPanelView: View {
    /// Width of the list; the preview pane adds `ClipboardPreviewPane.width` to its right.
    static let width: CGFloat = 512
    static let height: CGFloat = 560

    static func size(showsPreview: Bool) -> NSSize {
        NSSize(width: width + (showsPreview ? ClipboardPreviewPane.width : 0), height: height)
    }

    private static let listSpace = "ClipboardPanelView.list"

    @ObservedObject var model: ClipboardPanelModel
    let focusRequest: Int
    /// Read from settings each time the panel opens.
    var interfaceStyle: InterfaceStyle?
    @Environment(\.interfaceStyle) private var environmentStyle
    @ObservedObject var layout = ClipboardPanelLayout()
    @State private var searchFocused = false
    @State private var hoveredIndex: Int?
    @State private var showingNumberHints = false
    @State private var rowFrames = ClipboardRowFrames()
    private var effectiveStyle: InterfaceStyle { interfaceStyle ?? environmentStyle }

    var body: some View {
        TypefluxSpotlightSurface(query: $model.query, mode: mode, focused: $searchFocused,
                                 prompt: L(model.category == .snippet
                                     ? "clipboard.snippet.search" : "clipboard.search.placeholder"),
                                 modes: ClipboardCategory.allCases.map { $0.spotlightMode }, onEscape: model.cancel) {
            HStack(spacing: 0) {
                list.frame(width: Self.width)
                if model.showsPreview || previewWidth > 0 { preview }
            }
        } hints: {
            footer
        }
        .frame(width: viewportWidth, height: Self.height)
        .allowsHitTesting(!isModal)
        .accessibilityHidden(isModal)
        .overlay(alignment: .bottom) { noticeToast }
        .overlay { if model.editingText != nil { ClipboardEditBeforePaste(model: model) } }
        .overlay { if model.snippetDraft != nil { ClipboardSnippetEditor(model: model) } }
        .overlay(alignment: .bottom) {
            if let pending = model.pendingConfirmation {
                ClipboardConfirmationBar(
                    message: pending.message, onCancel: model.cancelPending, onConfirm: model.confirmPending
                )
            }
        }
        .environment(\.askLauncherNumberHints, showingNumberHints)
        .environment(\.interfaceStyle, effectiveStyle)
        .background(AskLauncherCommandMonitor { showingNumberHints = $0 })
        .onAppear { searchFocused = !isModal }
        .onChange(of: focusRequest) { _ in searchFocused = !isModal }
        .onChange(of: isModal) { presented in searchFocused = !presented }
    }

    private var isModal: Bool {
        model.snippetDraft != nil || model.editingText != nil || model.pendingConfirmation != nil
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

    private var mode: Binding<String> {
        Binding(get: { model.category.rawValue }, set: { value in
            if let category = ClipboardCategory(rawValue: value) { model.category = category }
        })
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
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
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
                .font(.largeTitle.weight(.light))
            Text(model.query.isEmpty
                ? L(model.category == .snippet ? "clipboard.snippet.empty" : "clipboard.empty")
                : L("clipboard.search.noResults", model.query))
                .font(.callout)
        }
        .foregroundStyle(TypefluxColor.secondaryLabel.color)
    }

}

// MARK: - Footer

extension ClipboardPanelView {
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.appFilter != nil || model.isRecordingPaused {
                HStack(spacing: 8) {
                    if let app = model.appFilter {
                        ClipboardAppFilterChip(app: app) {
                            model.setAppFilter(nil)
                            searchFocused = true
                        }
                    }
                    if model.isRecordingPaused { ClipboardPausedChip { model.send(.togglePause) } }
                }
            }
            HStack(spacing: 2) {
                Text(L("clipboard.footer.count", model.visibleEntries.count))
                    .font(.footnote).foregroundStyle(TypefluxColor.secondaryLabel.color)
                Spacer(minLength: 0)
                if let entry = model.selectedEntry {
                    if !entry.kind.isTextual { footerButton(.quickLook, entry: entry) }
                    if entry.snippet == nil { footerButton(.togglePin, entry: entry) }
                    footerButton(.paste, entry: entry, primary: true)
                }
                ClipboardPanelToolbar(model: model)
            }
            HStack(spacing: 12) {
                keyboardHint("↑↓", title: L("clipboard.hint.navigate"))
                keyboardHint("⌘↵", title: L("clipboard.hint.plainPaste"))
                keyboardHint("⌘1–9", title: L("clipboard.hint.quickPaste"))
                Spacer(minLength: 0)
                keyboardHint("Esc", title: L("clipboard.hint.close"))
            }
            .font(.footnote).foregroundStyle(TypefluxColor.secondaryLabel.color)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .accessibilityIdentifier("clipboard.hints")
    }

    private func keyboardHint(_ key: String, title: String) -> some View {
        Text(key + " " + title).lineLimit(1)
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
            .font(.callout)
            .foregroundStyle(primary ? TypefluxColor.label.color : TypefluxColor.secondaryLabel.color)
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
            TypefluxGlassContainer(radius: .popover) {
                Text(notice).font(.callout).padding(.horizontal, 12).padding(.vertical, 7)
            }
            .padding(.bottom, 76)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}
