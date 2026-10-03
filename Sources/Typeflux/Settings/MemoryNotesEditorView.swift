import SwiftUI

/// Editing is an explicit user action; model-driven corrections still use P02 approval.
struct MemoryNotesEditorView: View {
    @ObservedObject var model: AskMemoryNotesSettingsModel
    let store: AskMemoryNoteStore
    let owner: String
    var correctionsEnabled = false
    @State private var query = ""
    @State private var editing: AskMemoryNote?
    @State private var text = ""
    @State private var retention = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(L("memory.search"), text: $query)
            AgentSettingsSection(title: L("ask.settings.notes.title"), detail: "\(model.notes.count)",
                                 footnote: L("memory.boundaries")) {
                ForEach(model.notes
                    .filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }) { note in
                        AgentSettingsRow(
                            icon: "brain",
                            title: note.text,
                            subtitle: provenance(note),
                            titleLineLimit: nil
                        ) {
                            if correctionsEnabled {
                                AgentSettingsIconButton(systemImage: "pencil", help: L("memory.correct")) {
                                    editing = note; text = note.text; retention = 0
                                }
                            }
                            AgentSettingsIconButton(
                                systemImage: "trash",
                                help: L("memory.deleteSource"),
                                role: .destructive
                            ) {
                                model.remove(note, from: store, owner: owner)
                            }
                        }
                    }
            }
            if let error = model.error {
                Text(error).foregroundStyle(StudioTheme.danger)
            }
        }
        .sheet(item: $editing) { note in
            VStack(alignment: .leading, spacing: 16) {
                Text(L("memory.correct")).font(.headline)
                TextEditor(text: $text).frame(height: 100)
                Picker(L("memory.retention"), selection: $retention) {
                    Text(L("memory.keepRetention")).tag(0)
                    Text(L("memory.forever")).tag(-1)
                    Text(L("memory.days7")).tag(7)
                    Text(L("memory.days30")).tag(30)
                }
                Text(L("memory.boundaries")).font(.caption).foregroundStyle(.secondary)
                if let error = model.error {
                    Text(error).foregroundStyle(StudioTheme.danger)
                }
                HStack {
                    Button(L("memory.cancel")) { editing = nil }
                    Spacer()
                    Button(L("memory.save")) {
                        let expiry = retention == 0 ? note.provenance?.expiry
                            : (retention > 0 ? Date().addingTimeInterval(Double(retention) * 86400) : nil)
                        if model.correct(note, text: text, expiry: expiry, from: store, owner: owner) {
                            editing = nil
                        }
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 480)
        }
        .onChange(of: owner) { _ in editing = nil; model.reload(from: store, owner: owner) }
    }

    private func provenance(_ note: AskMemoryNote) -> String {
        let source = note.provenance?.source == .correction ? L("memory.correction") : L("memory.explicit")
        let retention = note.provenance?.expiry
            .map { $0.formatted(date: .abbreviated, time: .omitted) } ?? L("memory.forever")
        return "\(source) · v\(note.provenance?.version ?? 1) · \(L("memory.account")) · \(retention)"
    }
}
