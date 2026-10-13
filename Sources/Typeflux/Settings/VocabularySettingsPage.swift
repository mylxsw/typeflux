import SwiftUI

struct VocabularySettingsPage: View {
    @ObservedObject var viewModel: StudioViewModel
    let filter: VocabularyFilter
    let onAdd: () -> Void
    let onEdit: (VocabularyEntry) -> Void
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\VocabularyEntry.createdAt, order: .reverse)]

    private var entries: [VocabularyEntry] {
        filter.entries(in: viewModel.vocabularyEntries, query: viewModel.searchQuery)
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                TypefluxEmptyState(emptyTitle, systemImage: "text.book.closed",
                                   description: L("vocabulary.empty.subtitle")) {
                    TypefluxButton(kind: .regular, action: onAdd) {
                        Label(addTitle, systemImage: "plus")
                    }
                    .accessibilityIdentifier("vocabulary.empty.add")
                }
            } else {
                table
            }
        }
        .background(TypefluxColor.contentBackground.color)
        .onChange(of: entries.map(\.id)) { selection.formIntersection($0) }
    }

    private var query: String {
        viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var emptyTitle: String {
        query.isEmpty ? L("vocabulary.empty.title") : L("vocabulary.empty.noMatch", query)
    }

    private var addTitle: String {
        query.isEmpty ? L("vocabulary.action.addFirst") : L("vocabulary.action.addQuery", query)
    }

    private var table: some View {
        TypefluxTable(entries, selection: $selection, sortOrder: $sortOrder,
                      onDelete: deleteSelection, identifier: "vocabulary.table", stripesEmptyRows: false) {
            TableColumn(L("vocabulary.table.term"), value: \.term) { entry in
                TypefluxTableCell(rowID: entry.id) { Text(entry.term).lineLimit(1).help(entry.term) }
            }.width(min: 120, ideal: 220)
            TableColumn(L("vocabulary.table.source"), value: \.sourceTitle) { entry in
                TypefluxTableCell(rowID: entry.id) {
                    TypefluxTag(entry.sourceTitle, tone: entry.source == .automatic ? .accent : .neutral)
                }
            }.width(min: 80, ideal: 100)
            TableColumn(L("vocabulary.table.uses"), value: \.occurrenceCount) { entry in
                TypefluxTableCell(rowID: entry.id) { Text(entry.occurrenceCount, format: .number).monospacedDigit() }
            }.width(min: 60, ideal: 75)
            TableColumn(L("vocabulary.table.added"), value: \.createdAt) { entry in
                TypefluxTableCell(rowID: entry.id) { Text(entry.createdAt, style: .date) }
            }.width(min: 90, ideal: 120)
            TableColumn("") { entry in
                TypefluxTableActions(rowID: entry.id, selected: selection.contains(entry.id)) {
                    HStack {
                        TypefluxIconButton(L("common.copy"), systemImage: "doc.on.doc") {
                            viewModel.copyVocabularyTerm(entry.term)
                        }
                        TypefluxIconButton(L("common.edit"), systemImage: "pencil") { onEdit(entry) }
                        TypefluxIconButton(L("common.delete"), systemImage: "trash") {
                            viewModel.removeVocabularyEntry(id: entry.id)
                        }
                    }
                }
            }.width(100)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let entry = entries.first(where: { ids.contains($0.id) }), ids.count == 1 {
                Button(L("common.copy")) { viewModel.copyVocabularyTerm(entry.term) }
                Button(L("common.edit")) { onEdit(entry) }
            }
            if !ids.isEmpty {
                Button(L("common.delete"), role: .destructive) { delete(ids) }
            }
        }
    }

    private func delete(_ ids: Set<UUID>) {
        for id in ids {
            viewModel.removeVocabularyEntry(id: id)
        }
        selection.subtract(ids)
    }

    private func deleteSelection() {
        delete(selection)
    }
}

extension VocabularyEntry {
    var sourceTitle: String {
        source.displayName
    }
}
