import SwiftUI

struct EmojiResultsView: View {
    static let columns = 8
    static let height: CGFloat = 318
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

    private var selected: EmojiResult? {
        presentation.results.first { $0.id == output.selected?.id }
    }

    private func action(_ kind: AskPluginAction.Kind) {
        onAction(AskPluginAction(kind: kind, title: "", symbol: ""))
    }

    private func tile(_ result: EmojiResult) -> some View {
        Button {
            if onSelect(result.id) {
                focusedID = result.id
            }
        } label: {
            VStack(spacing: 4) {
                Text(result.sequence).font(.system(size: 27))
                Text(result.name).font(.system(size: 9)).lineLimit(1)
            }.frame(maxWidth: .infinity).frame(height: 57)
                .background(
                    selected?.id == result.id ? AskTheme.accent.opacity(0.15) : AskTheme
                        .hoverFill,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                    selected?.id == result.id ? AskTheme.accent : Color.clear
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
        .accessibilityAddTraits(selected?.id == result.id ? .isSelected : [])
        .accessibilityIdentifier("emoji.item." + result.id)
        .id(result.id)
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: Self.columns),
                            spacing: 5
                        ) {
                            ForEach(presentation.results) { result in
                                tile(result)
                            }
                        }
                    }
                    .onChange(of: output.selected?.id) { id in
                        if let id {
                            proxy.scrollTo(id, anchor: .center)
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
            case .copy: onMain()
            case .insert:
                if let action = output.action(for: .optionEnter) {
                    onAction(action)
                }
            case .copyAndStay: action(.emoji(.copyAndStay))
            }
        })
        .accessibilityIdentifier("emoji.results")
    }
}
