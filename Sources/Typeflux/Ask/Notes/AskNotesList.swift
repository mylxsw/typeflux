import SwiftUI

/// The native sidebar list owns keyboard navigation and multi-selection.
struct AskNotesList: View {
    @Environment(\.interfaceStyle) private var style
    @ObservedObject var model: AskNotesViewModel

    var body: some View {
        List(selection: Binding(get: { model.listSelection }, set: model.selectFromList)) {
            ForEach(model.sections) { section in
                Section(section.title) {
                    ForEach(section.notes) { note in
                        AskNotesListRow(note: note, model: model).tag(note.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, TypefluxControlHeight.sidebarRow.value(for: style))
        .overlay {
            if model.notes.isEmpty {
                TypefluxEmptyState(emptyText, systemImage: model.inTrash ? "trash" : "note.text",
                                   description: "") {
                    if !model.searchText.isEmpty, !model.inTrash {
                        TypefluxButton(L("ask.notes.newTitled", AskNotesViewModel.parseSearch(model.searchText).text)) {
                            model.createNote(title: AskNotesViewModel.parseSearch(model.searchText).text)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if model.inTrash { Text(L("ask.notes.trash.hint")) }
                Text(L("ask.notes.count", model.notes.count))
                Label(L("ask.notes.localOnly"), systemImage: "lock")
            }
            .font(.caption).foregroundStyle(TypefluxColor.secondaryLabel.color)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("ask.notes.list")
    }

    private var emptyText: String {
        if model.inTrash { return L("ask.notes.trash.none") }
        return L(model.searchText.isEmpty && model.scope == .all ? "ask.notes.empty" : "ask.notes.noMatch")
    }
}
