import AppKit
import SwiftUI

/// The action library: search everything, browse by type, and pick with one click. Hovering an
/// item previews it in the ring through `preview`.
struct RingLibraryPanel: View {
    let target: RingLibraryTarget
    let actions: [RingAction]
    let library: RingActionLibrary
    let isLoadingApps: Bool
    @Binding var preview: RingLibraryItem?
    var onPick: (RingLibraryItem) -> Void = { _ in }
    var onClose: (() -> Void)?
    var onOpenType: (RingActionType) -> Void = { _ in }

    @State private var category: RingActionType?
    @State private var query: String
    @State private var highlighted: Int?
    @State private var urlText: String

    /// `category`, `query` and `url` open the panel part-way through, as when it is restored.
    init(target: RingLibraryTarget, actions: [RingAction], library: RingActionLibrary, isLoadingApps: Bool,
         preview: Binding<RingLibraryItem?>, category: RingActionType? = nil, query: String = "", url: String = "",
         onPick: @escaping (RingLibraryItem) -> Void = { _ in }, onClose: (() -> Void)? = nil,
         onOpenType: @escaping (RingActionType) -> Void = { _ in }) {
        self.target = target
        self.actions = actions
        self.library = library
        self.isLoadingApps = isLoadingApps
        _preview = preview
        _category = State(initialValue: category)
        _query = State(initialValue: query)
        _urlText = State(initialValue: url)
        self.onPick = onPick
        self.onClose = onClose
        self.onOpenType = onOpenType
    }

    private var visibleItems: [RingLibraryItem] {
        if let category {
            return category == .url ? [] : library.items(of: category, matching: query)
        }
        if TFSearchMatcher.normalized(query).isEmpty {
            return library.recommendations(excluding: actions)
        }
        return library.search(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if category != .keys, category != .url {
                TFSearchField(placeholder: L("ring.library.search"), text: $query, placement: .container,
                              focusOnAppear: true, onMoveDown: moveHighlight, onSubmit: submit,
                              identifier: "ring.library.search")
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { content }
                        .padding(.horizontal, 12).padding(.bottom, 12)
                }
                .onChange(of: highlighted) { value in
                    if let value {
                        withAnimation { proxy.scrollTo(value, anchor: .center) }
                    }
                }
            }
        }
        .onChange(of: query) { _ in
            highlighted = nil
            preview = nil
        }
        .onChange(of: category) { _ in
            query = ""
            highlighted = nil
            preview = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        let title = switch target {
        case .insert: L("ring.actions.add")
        case let .replace(id): L("ring.library.replace", actions.first { $0.id == id }?.title ?? "")
        }
        return RingInspectorHeader(backTitle: category == nil ? nil : L("ring.library.allTypes"),
                                   onBack: category == nil ? nil : { category = nil },
                                   title: category?.title ?? title,
                                   onClose: actions.isEmpty ? nil : onClose)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch category {
        case nil:
            if TFSearchMatcher.normalized(query).isEmpty {
                home
            } else if visibleItems.isEmpty {
                emptyResult(L("ring.library.noResults"))
            } else {
                itemList(visibleItems, grouped: true)
            }
        case .keys?:
            keysForm
        case .url?:
            urlForm
        case let type?:
            if type == .app, isLoadingApps, library.apps.isEmpty {
                emptyResult(L("ring.editor.loadingApps"))
            } else if visibleItems.isEmpty {
                emptyResult(L("ring.library.noResults"))
            } else {
                itemList(visibleItems, grouped: true)
            }
            if type == .folder {
                chooseFolderRow.padding(.top, 4)
            }
        }
    }

    @ViewBuilder private var home: some View {
        let recommended = visibleItems
        if !recommended.isEmpty {
            RingLibraryChips(items: recommended, highlighted: highlighted, onHover: hover, onPick: onPick)
                .padding(.top, 4).padding(.bottom, 12)
        }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(RingActionLibrary.types, id: \.self) { type in
                RingTypeCard(type: type) {
                    category = type
                    onOpenType(type)
                }
            }
        }
    }

    /// Headings appear only when the list mixes groups; a single group is already named by the header.
    private func itemList(_ items: [RingLibraryItem], grouped: Bool) -> some View {
        let showsGroups = grouped && Set(items.map(\.group)).count > 1
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if showsGroups, index == 0 || items[index - 1].group != item.group {
                    groupHeader(item.group)
                }
                RingLibraryRow(item: item, query: query, isHighlighted: highlighted == index,
                               isAdded: RingActionLibrary.contains(item, in: actions)) { onPick(item) }
                    .id(index)
                    .onHover { inside in hover(inside ? index : nil, item: item) }
            }
        }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(TFColors.textTertiary)
            .padding(.horizontal, 4).padding(.top, 10).padding(.bottom, 5)
    }

    private func emptyResult(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(TFColors.textSecondary)
            .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 28)
    }

    private var pickTitle: String {
        if case .replace = target {
            return L("ring.library.pickReplace")
        }
        return L("ring.library.pickAdd")
    }

    // MARK: - Typed targets

    private var keysForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            RingKeysRecorderCard { onPick(RingActionLibrary.keysItem($0)) }
                .padding(.top, 4).padding(.bottom, 6)
            itemList(visibleItems, grouped: true)
        }
    }

    private var urlForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            RingURLForm(text: $urlText, pickTitle: pickTitle, onChange: { preview = $0 }, onPick: onPick)
        }
    }

    private var chooseFolderRow: some View {
        Button {
            if let path = RingFolderPicker.choose() {
                onPick(RingActionLibrary.folderItem(path))
            }
        } label: {
            Label(L("ring.library.chooseFolder"), systemImage: "folder.badge.plus")
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(TFColors.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).frame(height: 36).contentShape(Rectangle())
        }
        .buttonStyle(RingRowButtonStyle())
    }

    // MARK: - Keyboard and preview

    private func hover(_ index: Int?, item: RingLibraryItem) {
        if let index {
            highlighted = index
            preview = item
        } else if preview?.id == item.id {
            preview = nil
            highlighted = nil
        }
    }

    private func moveHighlight() {
        let items = visibleItems
        guard let next = Self.nextHighlight(after: highlighted, count: items.count) else { return }
        highlighted = next
        preview = items[next]
    }

    private func submit() {
        if let item = Self.submission(visibleItems, highlighted: highlighted, query: query) {
            onPick(item)
        }
    }
}

extension RingLibraryPanel {
    /// ↓ in the search field: the next result, wrapping to the first.
    static func nextHighlight(after current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return current.map { ($0 + 1) % count } ?? 0
    }

    /// Return in the search field: the highlighted result, or the first one while searching.
    static func submission(_ items: [RingLibraryItem], highlighted: Int?, query: String) -> RingLibraryItem? {
        if let highlighted, items.indices.contains(highlighted) {
            return items[highlighted]
        }
        return TFSearchMatcher.normalized(query).isEmpty ? nil : items.first
    }
}
