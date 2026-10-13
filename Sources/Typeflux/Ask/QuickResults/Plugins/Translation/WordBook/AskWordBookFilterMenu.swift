import SwiftUI

/// Native menus replace shelf chips, sort controls and private settings surfaces.
struct AskWordBookFilterMenu: View {
    @ObservedObject var model: AskWordBookViewModel
    @State private var confirmsClear = false

    var body: some View {
        Menu {
            shelf(.all)
            shelf(.starred)
            shelf(.today)
            shelf(.week)
            Section(L("ask.wordBook.shelf.languages")) {
                ForEach(model.pairs, id: \.self) { shelf(.pair($0)) }
            }
            Picker(L("ask.wordBook.sort"), selection: $model.sort) {
                Text(L("ask.wordBook.sort.recent")).tag(AskWordBookQuery.Sort.recent)
                Text(L("ask.wordBook.sort.count")).tag(AskWordBookQuery.Sort.count)
                Text(L("ask.wordBook.sort.alphabetical")).tag(AskWordBookQuery.Sort.alphabetical)
                Text(L("ask.wordBook.sort.starred")).tag(AskWordBookQuery.Sort.starred)
            }
            Menu(L("ask.wordBook.export")) {
                ForEach(AskWordBookExporter.Format.allCases) { format in
                    Button(format.title) { model.export(format) }
                }
            }
            Section(L("ask.wordBook.settings")) {
                Toggle(L("ask.wordBook.settings.record"), isOn: $model.recordsHistory)
                Picker(L("ask.wordBook.settings.retention"), selection: $model.retention) {
                    ForEach(AskWordBookRetention.allCases, id: \.self) { retention in
                        Text(retention.days.map { L("ask.wordBook.settings.days", $0) }
                             ?? L("ask.wordBook.settings.forever")).tag(retention)
                    }
                }
                Button(L("ask.wordBook.settings.clear"), role: .destructive) { confirmsClear = true }
            }
        } label: {
            Label(model.title(of: model.shelf), systemImage: "line.3.horizontal.decrease").labelStyle(.iconOnly)
        }
        .help(model.title(of: model.shelf))
        .accessibilityLabel(model.title(of: model.shelf))
        .accessibilityIdentifier("ask.wordBook.filter")
        .confirmationDialog(L("ask.wordBook.settings.clear.confirm", max(0, (model.counts[.all] ?? 0)
            - (model.counts[.starred] ?? 0))), isPresented: $confirmsClear) {
            Button(L("ask.wordBook.settings.clear"), role: .destructive, action: model.clearHistory)
            Button(L("common.cancel"), role: .cancel) {}
        }
    }

    private func shelf(_ shelf: AskWordBookViewModel.Shelf) -> some View {
        Button { model.shelf = shelf } label: {
            if model.shelf == shelf {
                Label(model.title(of: shelf), systemImage: "checkmark")
            } else {
                Text(model.title(of: shelf))
            }
        }
    }
}
