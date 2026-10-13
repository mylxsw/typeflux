import SwiftUI

struct AskWordBookList: View {
    @ObservedObject var model: AskWordBookViewModel

    var body: some View {
        List(selection: Binding(get: { model.transient == nil ? model.selectedKey : nil },
                                set: { model.selectedKey = $0 })) {
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        AskWordBookRow(entry: entry).tag(entry.key)
                            .contextMenu {
                                Button(L(entry.isStarred ? "ask.wordBook.unstar" : "ask.wordBook.star")) {
                                    model.toggleStar(entry)
                                }
                                Button(L("ask.wordBook.delete"), role: .destructive) { model.delete(entry) }
                            }
                            .onAppear { if entry.key == model.entries.last?.key { model.loadMore() } }
                    }
                } header: {
                    if let period = section.period { Text(period.title) }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.entries.isEmpty {
                TypefluxEmptyState(L(model.filterText.isEmpty
                    ? (model.shelf == .starred ? "ask.wordBook.empty.starred" : "ask.wordBook.empty.shelf")
                    : "ask.wordBook.empty.search"), systemImage: "book.closed", description: "")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if !model.recordsHistory { Label(L("ask.wordBook.paused"), systemImage: "pause.circle") }
                Text("\(model.streak) " + L("ask.wordBook.streak"))
                Text(L("ask.wordBook.weekTotal", model.weekTotal))
                AskWordBookActivity(model: model)
                Text(L("ask.wordBook.wordCount", model.entries.count))
                Label(L("ask.wordBook.localOnly"), systemImage: "lock")
            }
            .font(.caption).foregroundStyle(TypefluxColor.secondaryLabel.color)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("ask.wordBook.list")
    }
}
