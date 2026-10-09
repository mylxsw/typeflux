import SwiftUI

// swiftlint:disable file_length type_body_length

/// The notes window, drawn like the word book: shelves on the left, the list, and the
/// chosen note to read or edit (`docs/design/ai-command-results.md`).
struct AskNotesView: View {
    @ObservedObject var model: AskNotesViewModel
    var onClose: () -> Void
    @State private var titleDraft = ""
    @State private var tagDraft = ""
    @FocusState private var focus: Field?

    enum Field: Hashable { case search, title, tag, body }

    static let sidebarWidth: CGFloat = 210
    static let listWidth: CGFloat = 310
    static let trafficLightClearance: CGFloat = 44

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
                .frame(maxHeight: .infinity)
                .background(AskWordBookBackground(fill: StudioTheme.sidebar))
                .overlay(alignment: .trailing) { Rectangle().fill(StudioTheme.border).frame(width: 1) }
            HStack(alignment: .top, spacing: 14) {
                list.frame(width: Self.listWidth).askWordBookCard()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity).askWordBookCard()
            }
            .padding(StudioTheme.contentInset)
            .padding(.top, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AskWordBookBackground(fill: StudioTheme.shellSurface))
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottom) { noticeBar }
        .background(shortcuts)
        .onAppear { titleDraft = model.selected?.title ?? "" }
        .onChange(of: model.selectedID) { _ in titleDraft = model.selected?.title ?? "" }
        .onChange(of: model.selected?.title) { title in if focus != .title { titleDraft = title ?? "" } }
        .accessibilityIdentifier("ask.notes")
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: Self.trafficLightClearance)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    shelfRow(.all, symbol: "note.text", count: model.counts[.all] ?? 0)
                    shelfRow(.pinned, symbol: "pin", count: model.counts[.pinned] ?? 0)
                    if !model.commands.isEmpty {
                        groupTitle(L("ask.notes.shelf.commands"))
                        ForEach(model.commands) { facet in
                            shelfRow(.command(facet.name), symbol: "wand.and.stars", count: facet.count)
                        }
                    }
                    groupTitle(L("ask.notes.shelf.tags"))
                    if model.tags.isEmpty {
                        Text(L("ask.notes.noTags")).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                            .padding(.horizontal, 10).frame(height: 28)
                    }
                    ForEach(model.tags) { facet in
                        shelfRow(.tag(facet.name), symbol: "number", count: facet.count)
                    }
                }
                .padding(.horizontal, 12)
            }
            HStack(spacing: 4) {
                Image(systemName: "lock").font(.system(size: 10))
                Text(L("ask.notes.localOnly")).font(.system(size: 11)).lineLimit(1)
            }
            .foregroundStyle(StudioTheme.textTertiary)
            .padding(14)
        }
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title).font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
            .foregroundStyle(StudioTheme.textTertiary)
            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
    }

    private func shelfRow(_ scope: AskNoteQuery.Scope, symbol: String, count: Int) -> some View {
        let active = model.scope == scope
        let title = model.title(of: scope)
        return Button { model.scope = scope } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: StudioTheme.Typography.iconSmall, weight: .medium))
                    .foregroundStyle(active ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .frame(width: 18)
                Text(title).font(.studioBody(StudioTheme.Typography.body, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 32)
            .background(active ? AskWordBookStyle.selection : Color.clear,
                        in: RoundedRectangle(cornerRadius: AskWordBookStyle.fieldCorner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioInteractiveButtonStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textTertiary)
                    TextField(L("ask.notes.search"), text: $model.searchText)
                        .textFieldStyle(.plain).font(.system(size: 12.5))
                        .focused($focus, equals: .search)
                        .accessibilityIdentifier("ask.notes.search")
                }
                .padding(.horizontal, 9).frame(height: 30)
                .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioTheme.border))
                Picker("", selection: $model.sort) {
                    Text(L("ask.notes.sort.updated")).tag(AskNoteQuery.Sort.updated)
                    Text(L("ask.notes.sort.created")).tag(AskNoteQuery.Sort.created)
                }
                .labelsHidden().fixedSize()
            }
            .padding(10)
            Rectangle().fill(StudioTheme.border).frame(height: 1)
            if model.notes.isEmpty {
                emptyList
            } else {
                ScrollViewReader { reader in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 2) {
                            ForEach(model.notes) { note in row(note).id(note.id) }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.selectedID) { id in if let id { reader.scrollTo(id) } }
                }
            }
        }
    }

    private var emptyList: some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text").font(.system(size: 26)).foregroundStyle(StudioTheme.textTertiary)
            Text(L(model.searchText.isEmpty && model.scope == .all ? "ask.notes.empty" : "ask.notes.noMatch"))
                .font(.system(size: 12.5)).foregroundStyle(StudioTheme.textTertiary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ note: AskNote) -> some View {
        let active = note.id == model.selectedID
        return Button {
            // A title being typed is kept before another note replaces it.
            if focus == .title { model.rename(titleDraft) }
            model.select(note.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if note.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 9.5)).foregroundStyle(StudioTheme.accent)
                    }
                    Text(note.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.shortDate(model.sort == .created ? note.createdAt : note.updatedAt))
                        .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                }
                Text(note.excerpt).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
                HStack(spacing: 4) {
                    tag(note.command, accent: true)
                    ForEach(note.tags.prefix(3), id: \.self) { tag("#" + $0, accent: false) }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? AskWordBookStyle.selection : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioInteractiveButtonStyle())
        .accessibilityLabel(note.title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func tag(_ text: String, accent: Bool) -> some View {
        Text(text).font(.system(size: 10.5)).lineLimit(1)
            .foregroundStyle(accent ? StudioTheme.accent : StudioTheme.textSecondary)
            .padding(.horizontal, 6).frame(height: 18)
            .background(accent ? StudioTheme.accent.opacity(0.14) : StudioTheme.controlSurface,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    static func shortDate(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.defaultDigits).day())
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if let note = model.selected {
            VStack(alignment: .leading, spacing: 0) {
                header(note)
                if !note.input.isEmpty {
                    DisclosureGroup {
                        ScrollView(.vertical) {
                            Text(note.input).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                        .frame(maxHeight: 90)
                    } label: {
                        Text(L("ask.result.original")).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 6)
                    .overlay(alignment: .bottom) { Rectangle().fill(StudioTheme.border).frame(height: 1) }
                }
                if model.editing {
                    editor
                } else {
                    ScrollView(.vertical) {
                        AskTranscriptText(text: note.body)
                            .frame(maxWidth: AskResultWindowView.readingWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                    .frame(maxHeight: .infinity)
                }
                footer
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "star").font(.system(size: 28)).foregroundStyle(StudioTheme.textTertiary)
                Text(L("ask.notes.empty")).font(.system(size: 13)).foregroundStyle(StudioTheme.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ note: AskNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                TextField(L("ask.notes.title.placeholder"), text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .bold))
                    .focused($focus, equals: .title)
                    .onSubmit { model.rename(titleDraft); focus = nil }
                    .onChange(of: focus) { field in if field != .title { model.rename(titleDraft) } }
                    .accessibilityIdentifier("ask.notes.title")
                Button(action: model.togglePin) {
                    Image(systemName: note.pinned ? "pin.fill" : "pin").font(.system(size: 12))
                        .foregroundStyle(note.pinned ? StudioTheme.accent : StudioTheme.textSecondary)
                        .frame(width: 28, height: 26)
                        .background(note.pinned ? StudioTheme.accent.opacity(0.16) : StudioTheme.controlSurface,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L(note.pinned ? "ask.notes.unpin" : "ask.notes.pin"))
                .accessibilityLabel(L(note.pinned ? "ask.notes.unpin" : "ask.notes.pin"))
            }
            HStack(spacing: 6) {
                tag(note.command + (note.keyword.isEmpty ? "" : " · " + note.keyword), accent: true)
                Text(metaLine(note)).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
            }
            HStack(spacing: 5) {
                ForEach(note.tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        Text("#" + tag).font(.system(size: 11))
                        Button { model.removeTag(tag) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("ask.notes.tag.remove", tag))
                    }
                    .foregroundStyle(StudioTheme.textSecondary)
                    .padding(.horizontal, 6).frame(height: 20)
                    .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                TextField(L("ask.notes.tag.add"), text: $tagDraft)
                    .textFieldStyle(.plain).font(.system(size: 11))
                    .frame(width: 100)
                    .padding(.horizontal, 6).frame(height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(StudioTheme.border, style: StrokeStyle(lineWidth: 1, dash: [3])))
                    .focused($focus, equals: .tag)
                    .onSubmit { model.addTag(tagDraft); tagDraft = ""; focus = .tag }
                    .accessibilityIdentifier("ask.notes.tag")
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(StudioTheme.border).frame(height: 1) }
    }

    private func metaLine(_ note: AskNote) -> String {
        var parts: [String] = []
        if let model = note.model { parts.append(model) }
        if let app = note.sourceApp { parts.append(L("ask.notes.from", app)) }
        parts.append(L("ask.notes.created", note.createdAt.formatted(date: .abbreviated, time: .shortened)))
        if note.isEdited { parts.append(L("ask.notes.edited")) }
        return parts.joined(separator: " · ")
    }

    private var editor: some View {
        HStack(spacing: 12) {
            TextEditor(text: $model.draftBody)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioTheme.border))
                .focused($focus, equals: .body)
                .accessibilityIdentifier("ask.notes.editor")
            ScrollView(.vertical) {
                AskTranscriptText(text: model.draftBody).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity)
        .onAppear { focus = .body }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if model.editing {
                footerButton(L("ask.notes.done") + " ⌘↩", symbol: "checkmark", primary: true,
                             action: model.finishEditing)
                footerButton(L("ask.workflow.cancel"), symbol: "xmark", primary: false, action: model.cancelEditing)
            } else {
                footerButton(L("ask.notes.edit"), symbol: "pencil", primary: false, action: model.beginEditing)
                footerButton(L("ask.plugin.action.copy"), symbol: "doc.on.doc", primary: false,
                             action: model.copySelected)
                footerButton(L("ask.plugin.action.copyRich"), symbol: "doc.richtext", primary: false,
                             action: model.copySelectedRich)
                footerButton(L("ask.plugin.action.openInWindow"), symbol: "macwindow.on.rectangle", primary: false,
                             action: model.openSelectedInWindow)
                if model.askAI != nil {
                    footerButton(L("ask.result.askAI"), symbol: "bubble.left", primary: false,
                                 action: model.askAIAboutSelected)
                }
            }
            Spacer(minLength: 8)
            footerButton(L("ask.notes.export"), symbol: "square.and.arrow.up", primary: false,
                         action: model.exportSelected)
            footerButton(L("ask.notes.delete"), symbol: "trash", primary: false, danger: true,
                         action: model.deleteSelected)
        }
        .padding(.horizontal, 12).frame(height: 46)
        .overlay(alignment: .top) { Rectangle().fill(StudioTheme.border).frame(height: 1) }
    }

    private func footerButton(_ title: String, symbol: String, primary: Bool, danger: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(.system(size: 12)).lineLimit(1)
            }
            .foregroundStyle(danger ? StudioTheme.danger : primary ? Color.white : StudioTheme.textSecondary)
            .padding(.horizontal, 9).frame(height: 26)
            .background(primary ? StudioTheme.accent : StudioTheme.controlSurface,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    @ViewBuilder private var noticeBar: some View {
        if let notice = model.notice {
            HStack(spacing: 10) {
                Text(notice).font(.system(size: 12)).foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                if model.noticeOffersUndo, !model.deleted.isEmpty {
                    Button(L("ask.notes.undo")) { model.undoDelete() }.controlSize(.small)
                }
                Button { model.notice = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                    .buttonStyle(.plain).foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(StudioTheme.cardSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(StudioTheme.border))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            .padding(.bottom, 60)
            .accessibilityIdentifier("ask.notes.notice")
        }
    }

    /// Keys for the list and the chosen note; typing in a field keeps its own keys.
    private var shortcuts: some View {
        let typing = focus != nil
        return ZStack {
            Button("") { focus = .search }.keyboardShortcut("f")
            Button("") { model.moveSelection(-1) }.keyboardShortcut(.upArrow, modifiers: []).disabled(typing)
            Button("") { model.moveSelection(1) }.keyboardShortcut(.downArrow, modifiers: []).disabled(typing)
            Button("") { model.editing ? model.finishEditing() : model.beginEditing() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("") { model.copySelectedRich() }.keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(typing)
            Button("") { model.openSelectedInWindow() }.keyboardShortcut("o")
            Button("") { model.deleteSelected() }.keyboardShortcut(.delete, modifiers: .command).disabled(typing)
            Button("") { model.undoDelete() }.keyboardShortcut("z").disabled(model.deleted.isEmpty || typing)
            Button("") { onClose() }.keyboardShortcut("w")
            Button("") { escape() }.keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func escape() {
        if model.editing { model.cancelEditing() } else if focus != nil { focus = nil } else { onClose() }
    }
}
