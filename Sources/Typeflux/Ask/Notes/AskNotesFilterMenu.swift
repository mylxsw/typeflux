import SwiftUI

/// Shelves are toolbar filters; the sidebar is reserved for the note list.
struct AskNotesFilterMenu: View {
    @ObservedObject var model: AskNotesViewModel

    var body: some View {
        Menu {
            shelf(.all)
            shelf(.pinned)
            shelf(.recent)
            Section(L("ask.notes.shelf.sources")) {
                ForEach(AskNoteSource.allCases, id: \.self) { source in
                    if model.sources[source, default: 0] > 0 {
                        shelf(.source(source))
                        if source == .command {
                            ForEach(model.commands) { shelf(.command($0.name)) }
                        }
                    }
                }
            }
            Section(L("ask.notes.shelf.tags")) {
                ForEach(model.tags) { shelf(.tag($0.name)) }
            }
            shelf(.trash)
            Divider()
            Picker(L("ask.notes.sort"), selection: $model.sort) {
                Text(L("ask.notes.sort.updated")).tag(AskNoteQuery.Sort.updated)
                Text(L("ask.notes.sort.created")).tag(AskNoteQuery.Sort.created)
                Text(L("ask.notes.sort.title")).tag(AskNoteQuery.Sort.title)
            }
            if model.agentSettings != nil {
                Section(L("ask.notes.agent.title")) {
                    Toggle(L("ask.notes.agent.enabled"), isOn: Binding(
                        get: { model.agentEnabled }, set: model.setAgentEnabled))
                    ForEach(model.tags) { tag in
                        Toggle("#" + tag.name, isOn: Binding(
                            get: { !model.isHiddenFromAgent(tag.name) },
                            set: { enabled in
                                if model.isHiddenFromAgent(tag.name) == enabled {
                                    model.toggleHiddenFromAgent(tag.name)
                                }
                            }))
                    }
                }
            }
        } label: {
            Label(model.title(of: model.scope), systemImage: "line.3.horizontal.decrease")
                .labelStyle(.iconOnly)
        }
        .help(model.title(of: model.scope))
        .accessibilityLabel(model.title(of: model.scope))
        .accessibilityIdentifier("ask.notes.filter")
    }

    private func shelf(_ scope: AskNoteQuery.Scope) -> some View {
        Button { model.scope = scope } label: {
            if model.scope == scope {
                Label(model.title(of: scope), systemImage: "checkmark")
            } else {
                Text(model.title(of: scope))
            }
        }
    }
}
