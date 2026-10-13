import SwiftUI

/// Saved notes: explained in plain words, searchable, added and corrected inline, removable with undo.
/// Editing is an explicit user action; model-driven corrections still use P02 approval.
struct MemoryNotesEditorView: View {
    @Environment(\.typefluxToolbarSearchQuery) private var toolbarQuery
    @ObservedObject var model: AskMemoryNotesSettingsModel
    let store: AskMemoryNoteStore
    let owner: String
    var correctionsEnabled = false
    @Binding var query: String

    init(model: AskMemoryNotesSettingsModel, store: AskMemoryNoteStore, owner: String,
         correctionsEnabled: Bool = false, query: Binding<String> = .constant("")) {
        self.model = model
        self.store = store
        self.owner = owner
        self.correctionsEnabled = correctionsEnabled
        _query = query
    }

    private var visibleNotes: [AskMemoryNote] {
        let text = (toolbarQuery ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        return model.notes.filter { text.isEmpty || $0.text.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        TypefluxForm {
            Section {
                TypefluxSettingsRow(L("agent.memory.count", model.notes.count)) {
                    Button {
                        query = ""
                        model.beginAdding()
                    } label: { Label(L("agent.memory.add"), systemImage: "plus") }
                        .buttonStyle(.borderedProminent).disabled(model.draft != nil)
                }
            }
            Section {
                if let draft = model.draft, draft.note == nil {
                    editor
                }
                if model.notes.isEmpty, model.draft == nil {
                    TypefluxEmptyState(L("agent.memory.emptyTitle"), systemImage: "brain",
                                       description: L("agent.memory.emptyMessage"))
                } else if visibleNotes.isEmpty, model.draft == nil {
                    AgentSettingsEmptyRow(text: L("agent.memory.noMatch"))
                }
                ForEach(visibleNotes) { note in
                    if model.draft?.note?.id == note.id {
                        editor
                    } else {
                        row(note)
                    }
                }
            }
            if let error = model.error {
                Text(error).font(.subheadline).foregroundStyle(TypefluxColor.danger.color)
            }
            if let removed = model.recentlyRemoved {
                AgentUndoBanner(message: L("agent.memory.removed"),
                                onUndo: { model.undoRemove(to: store, owner: owner) },
                                onDismiss: { model.dismissUndo() }).id(removed.id)
            }
        }
        .onChange(of: owner) { _ in
            model.cancelEditing()
            model.dismissUndo()
            model.reload(from: store, owner: owner)
        }
    }

    private func retentionOptions(isNew: Bool, currentExpiry: Date?) -> [(
        label: String,
        value: AskMemoryNotesSettingsModel.Retention
    )] {
        var options: [(label: String, value: AskMemoryNotesSettingsModel.Retention)] = []
        if !isNew {
            options.append((L(currentExpiry == nil ? "memory.forever" : "memory.keepRetention"), .keep))
        }
        if isNew || currentExpiry != nil {
            options.append((L("memory.forever"), .forever))
        }
        options += [(L("memory.days7"), .days(7)), (L("memory.days30"), .days(30))]
        return options
    }

    private func row(_ note: AskMemoryNote) -> some View {
        AgentSettingsRow(icon: "brain", title: note.text, subtitle: Self.provenance(note), titleLineLimit: nil) {
            HStack(spacing: 8) {
                if correctionsEnabled {
                    TypefluxIconButton(L("memory.correct"), systemImage: "pencil") {
                        model.beginEditing(note)
                    }
                    .disabled(model.draft != nil)
                }
                TypefluxIconButton(L("memory.deleteSource"), systemImage: "trash", kind: .destructive) {
                    model.remove(note, from: store, owner: owner)
                }
            }
        }
    }

    private var editor: some View {
        let isNew = model.draft?.note == nil
        let currentExpiry = model.draft?.note?.provenance?.expiry
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: Binding(get: { model.draft?.text ?? "" }, set: { model.draft?.text = $0 }))
                    .font(.body)
                    .frame(height: 90)
                    .accessibilityLabel(L(isNew ? "agent.memory.add" : "memory.correct"))
                HStack(spacing: 8) {
                    Text(L("memory.retention")).font(.subheadline).foregroundStyle(StudioTheme.textTertiary)
                    TypefluxPopup(title: L("memory.retention"),
                                  options: retentionOptions(isNew: isNew, currentExpiry: currentExpiry),
                                  selection: Binding(
                                      get: { model.draft?.retention ?? .keep },
                                      set: { model.draft?.retention = $0 }
                                  ))
                                  .frame(width: 150)
                    Spacer()
                    Button(L("memory.cancel")) { model.cancelEditing() }.buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                    Button(L(isNew ? "agent.memory.save" : "memory.save")) {
                        model.saveDraft(to: store, owner: owner)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.draft?.canSave != true)
                }
            }
        }
    }

    static func provenance(_ note: AskMemoryNote) -> String {
        let source = note.provenance?.source == .correction ? L("agent.memory.corrected") : L("agent.memory.explicit")
        let date = note.createdAt.formatted(date: .abbreviated, time: .omitted)
        let retention = note.provenance?.expiry
            .map { L("agent.memory.until", $0.formatted(date: .abbreviated, time: .omitted)) } ?? L("memory.forever")
        return "\(source) · \(date) · \(retention)"
    }
}
