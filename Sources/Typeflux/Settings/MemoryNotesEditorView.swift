import SwiftUI

/// Saved notes: explained in plain words, searchable, added and corrected inline, removable with undo.
/// Editing is an explicit user action; model-driven corrections still use P02 approval.
struct MemoryNotesEditorView: View {
    @ObservedObject var model: AskMemoryNotesSettingsModel
    let store: AskMemoryNoteStore
    let owner: String
    var correctionsEnabled = false
    @State private var query = ""

    private var visibleNotes: [AskMemoryNote] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.notes.filter { text.isEmpty || $0.text.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: TFMetrics.toolbarSpacing) {
                TFSearchField(placeholder: L("agent.memory.search"), text: $query, resultCount: visibleNotes.count)
                Spacer(minLength: 0)
                TFButton(title: L("agent.memory.addButton"), systemImage: "plus", kind: .primary) {
                    query = ""
                    model.beginAdding()
                }
                .disabled(model.draft != nil)
            }
            TFCard {
                if let draft = model.draft, draft.note == nil {
                    editor
                    if !visibleNotes.isEmpty { TFDivider.formWithIcon }
                }
                if model.notes.isEmpty, model.draft == nil {
                    TFEmptyState(systemImage: "brain", title: L("agent.memory.emptyTitle"),
                                 message: L("agent.memory.emptyMessage")) { EmptyView() }
                } else if visibleNotes.isEmpty, model.draft == nil {
                    TFCardNote(text: L("agent.memory.noMatch"))
                }
                ForEach(Array(visibleNotes.enumerated()), id: \.element.id) { index, note in
                    if index > 0 { TFDivider.formWithIcon }
                    if model.draft?.note?.id == note.id {
                        editor
                    } else {
                        row(note)
                    }
                }
            }
            if let error = model.error {
                TFFieldMessage(text: error)
            }
            if let removed = model.recentlyRemoved {
                TFUndoBar(message: L("agent.memory.removed"),
                          onUndo: { model.undoRemove(to: store, owner: owner) },
                          onDismiss: { model.dismissUndo() })
                    .id(removed.id)
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
        TFFormRow(title: note.text, valueText: Self.provenance(note), icon: "brain") {
            if correctionsEnabled {
                TFButton(title: L("memory.correct"), systemImage: "pencil", size: .small, iconOnly: true) {
                    model.beginEditing(note)
                }
                .disabled(model.draft != nil)
            }
            TFButton(title: L("memory.deleteSource"), systemImage: "trash", destructive: true, size: .small,
                     iconOnly: true) {
                model.remove(note, from: store, owner: owner)
            }
        }
    }

    private var editor: some View {
        let isNew = model.draft?.note == nil
        let currentExpiry = model.draft?.note?.provenance?.expiry
        return HStack(alignment: .top, spacing: 12) {
            TFIconTile(systemImage: isNew ? "plus" : "pencil", style: .soft)
            VStack(alignment: .leading, spacing: 8) {
                TFTextArea(label: L(isNew ? "agent.memory.add" : "memory.correct"),
                           text: Binding(get: { model.draft?.text ?? "" }, set: { model.draft?.text = $0 }),
                           isFocusedStyle: true)
                HStack(spacing: TFMetrics.toolbarSpacing) {
                    TFFootnote(text: L("memory.retention"))
                    TFPopUpButton(
                        title: L("memory.retention"),
                        options: retentionOptions(isNew: isNew, currentExpiry: currentExpiry)
                            .map { TFOption($0.value, $0.label) },
                        selection: Binding(
                            get: { model.draft?.retention ?? .keep },
                            set: { model.draft?.retention = $0 }
                        ),
                        width: 150
                    )
                    Spacer()
                    TFButton(title: L("memory.cancel")) { model.cancelEditing() }
                        .keyboardShortcut(.cancelAction)
                    TFButton(title: L(isNew ? "agent.memory.save" : "memory.save"), kind: .primary) {
                        model.saveDraft(to: store, owner: owner)
                    }
                    .disabled(model.draft?.canSave != true)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    static func provenance(_ note: AskMemoryNote) -> String {
        let source = note.provenance?.source == .correction ? L("agent.memory.corrected") : L("agent.memory.explicit")
        let date = note.createdAt.formatted(date: .abbreviated, time: .omitted)
        let retention = note.provenance?.expiry
            .map { L("agent.memory.until", $0.formatted(date: .abbreviated, time: .omitted)) } ?? L("memory.forever")
        return "\(source) · \(date) · \(retention)"
    }
}
