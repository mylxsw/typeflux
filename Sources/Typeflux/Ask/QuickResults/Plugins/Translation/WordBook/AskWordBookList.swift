import SwiftUI

struct AskWordBookList: View {
    @Environment(\.interfaceStyle) private var style
    @ObservedObject var model: AskWordBookViewModel

    var body: some View {
        List(selection: Binding(get: { model.transient == nil ? model.selectedKey : nil },
                                set: { model.selectedKey = $0 })) {
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        AskWordBookRow(entry: entry, selected: model.transient == nil && model.selectedKey == entry.key)
                            .tag(entry.key)
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
        .environment(\.defaultMinListRowHeight, TypefluxControlHeight.sidebarRow.value(for: style))
        .overlay(alignment: .topLeading) {
            if model.entries.isEmpty, model.shelf != .all || !model.filterText.isEmpty {
                let message = L(model.filterText.isEmpty
                    ? (model.shelf == .starred ? "ask.wordBook.empty.starred" : "ask.wordBook.empty.shelf")
                    : "ask.wordBook.empty.search")
                Text(message.components(separatedBy: "\n").first ?? message)
                    .font(.callout).foregroundStyle(TypefluxColor.secondaryLabel.color)
                    .lineLimit(1).help(message)
                    .padding(TypefluxSpacing.regular.value(for: style))
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
