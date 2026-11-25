import AppKit
import SwiftUI

struct EmojiResultsView: View {
    static let columns = 8
    static let height: CGFloat = 318
    fileprivate static let tileHeight: CGFloat = 57
    fileprivate static let gridSpacing: CGFloat = 5
    var output: AskPluginOutput
    var presentation: EmojiPresentation
    var contentHeight: CGFloat = Self.height
    var onSelect: (String) -> Bool
    var onMain: () -> Void
    var onAction: (AskPluginAction) -> Void

    @FocusState private var focusedID: String?

    static func nextIndex(_ index: Int, delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(max(0, index + delta), count - 1)
    }

    private func action(_ kind: AskPluginAction.Kind) {
        onAction(AskPluginAction(kind: kind, title: "", symbol: ""))
    }

    private func tile(_ result: EmojiResult, selected: Bool) -> some View {
        Button {
            if onSelect(result.id) {
                focusedID = result.id
            }
        } label: {
            VStack(spacing: 4) {
                Text(result.sequence).font(.system(size: 27))
                Text(result.name).font(.system(size: 9)).lineLimit(1)
            }.frame(maxWidth: .infinity).frame(height: Self.tileHeight)
                .background(
                    selected ? AskTheme.accent.opacity(0.15) : AskTheme.hoverFill,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                    selected ? AskTheme.accent : Color.clear
                ))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                action(.emoji(.favorite(result.id)))
            } label: {
                Label(
                    L(result.favorite ? "emoji.unfavorite" : "emoji.favorite"),
                    systemImage: result.favorite ? "star.fill" : "star"
                )
            }
            if !result.entry.variants.isEmpty {
                Menu(L("emoji.variant")) {
                    Button(result.entry.sequence) {
                        action(.emoji(.variant(id: result.id, sequence: result.entry.sequence)))
                    }
                    .accessibilityLabel(result.entry.name(presentation.language))
                    ForEach(result.entry.variants, id: \.sequence) { variant in
                        Button(variant.sequence) {
                            action(.emoji(.variant(id: result.id, sequence: variant.sequence)))
                        }
                        .accessibilityLabel(result.entry.name(presentation.language, sequence: variant.sequence))
                    }
                }
            }
        }
        .focused($focusedID, equals: result.id)
        .onMoveCommand { direction in
            let delta: Int
            switch direction {
            case .left: delta = -1
            case .right: delta = 1
            case .up: delta = -Self.columns
            case .down: delta = Self.columns
            default: return
            }
            guard let index = Self.nextIndex(
                output.selectedItem,
                delta: delta,
                count: presentation.results.count
            ) else { return }
            let id = presentation.results[index].id
            if onSelect(id) {
                focusedID = id
            }
        }
        .simultaneousGesture(TapGesture(count: 2)
            .onEnded {
                if onSelect(result.id) {
                    onMain()
                }
            })
        .accessibilityLabel(result.sequence + ", " + result.name + ", " + result.reason)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("emoji.item." + result.id)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                ForEach(EmojiScope.allCases, id: \.self) { scope in
                    Button(scope.title) { action(.rerun(["scope": scope.rawValue, "selectedID": ""])) }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(
                            scope == presentation.scope ? AskTheme.accent.opacity(0.15) : Color.clear,
                            in: Capsule()
                        )
                        .accessibilityAddTraits(scope == presentation.scope ? .isSelected : [])
                        .accessibilityIdentifier("emoji.scope." + scope.rawValue)
                }
                Text("\(presentation.results.count)").foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                if presentation.scope == .recent {
                    Button(L("emoji.clearRecent")) { action(.emoji(.clearRecent)) }.buttonStyle(.plain)
                        .accessibilityIdentifier("emoji.clearRecent")
                }
                Text(L("emoji.local")).foregroundStyle(StudioTheme.textSecondary)
            }.font(.system(size: 11))
            if presentation.results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "face.smiling").font(.system(size: 25))
                    Text(L("emoji.empty." + presentation.scope.rawValue))
                    Text(L("emoji.empty.hint")).font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let selectedID = output.selected?.id
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: Self.gridSpacing), count: Self.columns),
                        spacing: Self.gridSpacing
                    ) {
                        ForEach(presentation.results) { result in
                            tile(result, selected: result.id == selectedID)
                        }
                    }
                    .background(alignment: .topLeading) {
                        if let selectedID {
                            EmojiGridScrollAnchor(selection: .init(index: output.selectedItem, id: selectedID))
                                .frame(width: 1, height: 1)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: contentHeight)
        .background(EmojiGridKeyboard(focused: focusedID != nil) { key in
            switch key {
            case let .move(delta):
                guard let index = Self.nextIndex(output.selectedItem, delta: delta, count: presentation.results.count)
                else { return }
                let id = presentation.results[index].id
                if onSelect(id) {
                    focusedID = id
                }
            case .insert: onMain()
            case .copy:
                if let action = output.action(for: .optionEnter) {
                    onAction(action)
                }
            case .copyAndStay: action(.emoji(.copyAndStay))
            }
        })
        .accessibilityIdentifier("emoji.results")
    }
}

/// Reveals a fixed-height row directly, without asking the lazy grid to find an offscreen tile by ID.
private struct EmojiGridScrollAnchor: NSViewRepresentable {
    struct Selection: Equatable {
        let index: Int
        let id: String
    }

    var selection: Selection

    func makeNSView(context _: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context _: Context) {
        view.updateSelection(selection)
    }

    final class AnchorView: NSView {
        override var isFlipped: Bool { true }
        private var selection: Selection?
        private var scrollScheduled = false

        func updateSelection(_ selection: Selection) {
            guard self.selection != selection else { return }
            self.selection = selection
            scheduleScroll()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { scheduleScroll() }
        }

        private func scheduleScroll() {
            guard !scrollScheduled else { return }
            scrollScheduled = true
            // Wait for SwiftUI to place the grid and combine selection changes in this update.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                scrollScheduled = false
                revealSelection()
            }
        }

        private func revealSelection() {
            guard let selection, let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            let row = selection.index / EmojiResultsView.columns
            let tileHeight = EmojiResultsView.tileHeight
            let rowTop = CGFloat(row) * (tileHeight + EmojiResultsView.gridSpacing)
            let target = document.convert(NSRect(x: 0, y: rowTop, width: 1, height: tileHeight), from: self)
            if !scroll.documentVisibleRect.contains(target) {
                document.scrollToVisible(target)
            }
        }
    }
}
