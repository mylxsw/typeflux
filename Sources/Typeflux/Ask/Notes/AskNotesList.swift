import AppKit
import SwiftUI

enum AskNotesField: Hashable { case search, title, tag }

/// The middle column: the shelf's name, search, and the notes under day headings.
struct AskNotesList: View {
    @ObservedObject var model: AskNotesViewModel
    var focus: FocusState<AskNotesField?>.Binding
    var sidebarCollapsed = false
    @State private var showsSidebar = false

    var body: some View {
        VStack(spacing: 0) {
            if sidebarCollapsed { navigationBar }
            header
            searchField.padding(.horizontal, 12).padding(.bottom, 8)
            if model.inTrash {
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 11))
                    Text(L("ask.notes.trash.hint")).font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(StudioTheme.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            if model.notes.isEmpty {
                empty
            } else {
                ScrollViewReader { reader in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(model.sections) { section in
                                Text(section.title).font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(StudioTheme.textTertiary)
                                    .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                                ForEach(section.notes) { note in
                                    AskNotesListRow(note: note, model: model, focus: focus).id(note.id)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 70)
                    }
                    .onChange(of: model.selectedID) { id in if let id { withAnimation { reader.scrollTo(id) } } }
                }
            }
        }
        .accessibilityIdentifier("ask.notes.list")
        .onChange(of: sidebarCollapsed) { collapsed in if !collapsed { showsSidebar = false } }
        .onChange(of: model.scope) { _ in showsSidebar = false }
    }

    /// With the sidebar collapsed, "new note" and its toggle sit right-aligned
    /// in one glass pill, like the conversation sidebar's tools.
    private var navigationBar: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: AskResultWindowView.trafficLightClearance)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                AskIconGhostButton(label: L("ask.notes.new") + " ⌘N", systemImage: "square.and.pencil") {
                    model.perform { await model.createNote() }
                }
                AskIconGhostButton(label: L("ask.sidebar.toggle"), systemImage: "sidebar.left") {
                    showsSidebar.toggle()
                }
                .accessibilityIdentifier("ask.notes.sidebarToggle")
                .popover(isPresented: $showsSidebar, arrowEdge: .bottom) {
                    AskNotesSidebar(model: model, clearsTitleBar: false)
                        .frame(width: AskNotesView.sidebarWidth, height: 480)
                        .background(AskTheme.glassFill)
                }
            }
            .askCollapsedSidebarTools()
        }
        .padding(.trailing, 10)
        .frame(height: AskMetrics.titleBarRowHeight)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(model.title(of: model.scope)).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Text(L("ask.notes.count", model.notes.count)).font(.system(size: 12))
                .foregroundStyle(StudioTheme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if model.inTrash {
                if !model.notes.isEmpty {
                    Button(L("ask.notes.trash.empty")) { model.perform { await model.emptyTrash()  } }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(StudioTheme.danger)
                        .accessibilityIdentifier("ask.notes.trash.empty")
                }
            } else {
                if model.selecting {
                    Button(L("ask.notes.done")) { model.perform { await model.setSelecting(false)  } }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(AskTheme.accent)
                } else {
                    AskIconGhostButton(label: L("ask.notes.select"), systemImage: "checkmark.circle") {
                        model.perform { await model.setSelecting(true) }
                    }
                }
                Menu {
                    Picker(L("ask.notes.sort"), selection: $model.sort) {
                        Text(L("ask.notes.sort.updated")).tag(AskNoteQuery.Sort.updated)
                        Text(L("ask.notes.sort.created")).tag(AskNoteQuery.Sort.created)
                        Text(L("ask.notes.sort.title")).tag(AskNoteQuery.Sort.title)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(StudioTheme.textTertiary)
                .fixedSize()
                .help(L("ask.notes.sort"))
                .accessibilityLabel(L("ask.notes.sort"))
            }
        }
        .padding(.leading, 18).padding(.trailing, 10)
        .frame(height: sidebarCollapsed ? 40 : AskMetrics.titleBarRowHeight)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12.5)).foregroundStyle(StudioTheme.textTertiary)
            TextField(L("ask.notes.search"), text: $model.searchText)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused(focus, equals: .search)
                .onSubmit { focus.wrappedValue = nil }
                .accessibilityIdentifier("ask.notes.search")
            if model.searchText.isEmpty {
                AskKeyHint(text: "⌘F")
            } else {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("ask.notes.search.clear"))
            }
        }
        .askLibrarySearchSurface(focused: focus.wrappedValue == .search)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: model.inTrash ? "trash" : "note.text").font(.system(size: 24))
                .foregroundStyle(StudioTheme.textTertiary)
            Text(emptyText).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textTertiary)
                .multilineTextAlignment(.center)
            if !model.searchText.isEmpty, !model.inTrash {
                Button {
                    model.perform { await model.createNote(title: AskNotesViewModel.parseSearch(model.searchText).text) }
                } label: {
                    Label(L("ask.notes.newTitled", AskNotesViewModel.parseSearch(model.searchText).text),
                          systemImage: "plus")
                        .font(.system(size: 12.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AskTheme.accent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyText: String {
        if model.inTrash { return L("ask.notes.trash.none") }
        return L(model.searchText.isEmpty && model.scope == .all ? "ask.notes.empty" : "ask.notes.noMatch")
    }
}

struct AskNotesListRow: View {
    let note: AskNote
    @ObservedObject var model: AskNotesViewModel
    var focus: FocusState<AskNotesField?>.Binding
    @State private var hovering = false
    @Environment(\.interfaceStyle) private var style

    private var active: Bool { model.selecting ? model.picked.contains(note.id) : note.id == model.selectedID }

    var body: some View {
        Button(action: click) {
            HStack(alignment: .top, spacing: 10) {
                leading.padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(note.title.isEmpty ? L("ask.notes.untitled") : note.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Self.shortDate(listDate)).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                    }
                    if !note.excerpt.isEmpty {
                        Text(note.excerpt).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    if (note.source == .command && !note.command.isEmpty) || !note.tags.isEmpty { chips }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .askNotesRow(selected: active, hovering: hovering, corner: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { contextMenu }
        .accessibilityIdentifier("ask.notes.row")
        .accessibilityLabel(note.title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var listDate: Date {
        if note.isDeleted { return note.deletedAt ?? note.updatedAt }
        return model.sort == .created ? note.createdAt : note.updatedAt
    }

    @ViewBuilder private var leading: some View {
        if model.selecting {
            let picked = model.picked.contains(note.id)
            ZStack {
                Circle().strokeBorder(picked ? Color.clear : StudioTheme.textTertiary, lineWidth: 1.5)
                if picked {
                    Circle().fill(AskTheme.accent)
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 18, height: 18).frame(width: 22, height: 22)
        } else {
            let tint = AskNotesStyle.sourceColor(note.source)
            Image(systemName: note.source.symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if note.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 7.5)).foregroundStyle(AskTheme.accent)
                            .offset(x: 4, y: -4)
                    }
                }
        }
    }

    private var chips: some View {
        HStack(spacing: 4) {
            if note.source == .command, !note.command.isEmpty {
                Text(note.command).font(.system(size: 10.5)).lineLimit(1)
                    .foregroundStyle(Color(nsColor: .systemPurple))
                    .padding(.horizontal, 6).frame(height: 17)
                    .background(Color(nsColor: .systemPurple).opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            ForEach(note.tags.prefix(3), id: \.self) { tag in
                HStack(spacing: 3) {
                    Circle().fill(AskNotesStyle.tagColor(tag)).frame(width: 5, height: 5)
                    Text(tag).font(.system(size: 10.5)).lineLimit(1)
                }
                .foregroundStyle(StudioTheme.textSecondary)
                .padding(.horizontal, 6).frame(height: 17)
                .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder private var contextMenu: some View {
        if note.isDeleted {
            Button(L("ask.notes.trash.restore")) { model.perform { await model.select(note.id); await model.restoreFromTrash()  } }
            Button(L("ask.notes.trash.deleteForever"), role: .destructive) {
                model.perform { await model.select(note.id); await model.deleteForever() }
            }
        } else {
            Button(L(note.pinned ? "ask.notes.unpin" : "ask.notes.pin")) { model.perform { await model.select(note.id); await model.togglePin()  } }
            Button(L("ask.plugin.action.copy")) { model.perform { await model.select(note.id); model.copySelected()  } }
            Button(L("ask.plugin.action.openInWindow")) { model.perform { await model.select(note.id); model.openSelectedInWindow()  } }
            Divider()
            Button(L("ask.notes.delete"), role: .destructive) { model.perform { await model.select(note.id); await model.deleteSelected()  } }
        }
    }

    private func click() {
        // A title being typed is kept before another note replaces it.
        if focus.wrappedValue == .title { focus.wrappedValue = nil }
        let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        if !model.inTrash, flags.contains(.shift) {
            model.perform { await model.pickRange(to: note.id) }
        } else if !model.inTrash, flags.contains(.command) || model.selecting {
            model.perform { await model.togglePick(note.id) }
        } else {
            model.perform { await model.select(note.id) }
        }
    }

    static func shortDate(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.defaultDigits).day())
    }
}
