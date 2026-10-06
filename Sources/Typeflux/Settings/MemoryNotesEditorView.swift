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
            HStack(spacing: 10) {
                AgentSearchBox(placeholder: L("agent.memory.search"), text: $query)
                Spacer()
                Button {
                    query = ""
                    model.beginAdding()
                } label: {
                    Label(L("agent.memory.add"), systemImage: "plus")
                }
                .buttonStyle(ModelActionStyle(primary: true))
                .disabled(model.draft != nil)
            }
            ModelSurface {
                VStack(alignment: .leading, spacing: 0) {
                    if let draft = model.draft, draft.note == nil {
                        editor
                        if !visibleNotes.isEmpty { ModelRowDivider(leading: 66) }
                    }
                    if model.notes.isEmpty, model.draft == nil {
                        AgentEmptyState(symbol: "brain", title: L("agent.memory.emptyTitle"),
                                        message: L("agent.memory.emptyMessage")) { EmptyView() }
                    } else if visibleNotes.isEmpty, model.draft == nil {
                        AgentSettingsEmptyRow(text: L("agent.memory.noMatch"))
                    }
                    ForEach(Array(visibleNotes.enumerated()), id: \.element.id) { index, note in
                        if index > 0 { ModelRowDivider(leading: 66) }
                        if model.draft?.note?.id == note.id {
                            editor
                        } else {
                            row(note)
                        }
                    }
                }
            }
            if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundStyle(StudioTheme.danger)
            }
            if let removed = model.recentlyRemoved {
                AgentUndoBanner(message: L("agent.memory.removed"),
                                onUndo: { model.undoRemove(to: store, owner: owner) },
                                onDismiss: { model.dismissUndo() })
                    .id(removed.id)
            }
            AgentRulesCard(title: L("agent.memory.rules.title"), rules: Self.rules).padding(.top, 12)
            Text(L("agent.memory.historyNote")).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                .padding(.horizontal, 4)
        }
        .onChange(of: owner) { _ in
            model.cancelEditing()
            model.dismissUndo()
            model.reload(from: store, owner: owner)
        }
    }

    /// How saved notes are used, saved and forgotten.
    static var rules: [(title: String, detail: String?)] {
        [(L("agent.memory.rule.use.title"), L("agent.memory.rule.use.detail")),
         (L("agent.memory.rule.ask.title"), L("agent.memory.rule.ask.detail")),
         (L("agent.memory.rule.delete.title"), L("agent.memory.rule.delete.detail"))]
    }

    private func row(_ note: AskMemoryNote) -> some View {
        AgentSettingsRow(icon: "brain", title: note.text, subtitle: Self.provenance(note), titleLineLimit: nil) {
            HStack(spacing: 8) {
                if correctionsEnabled {
                    AgentSettingsIconButton(systemImage: "pencil", help: L("memory.correct")) {
                        model.beginEditing(note)
                    }
                    .disabled(model.draft != nil)
                }
                AgentSettingsIconButton(systemImage: "trash", help: L("memory.deleteSource"), role: .destructive) {
                    model.remove(note, from: store, owner: owner)
                }
            }
        }
    }

    private var editor: some View {
        let isNew = model.draft?.note == nil
        let currentExpiry = model.draft?.note?.provenance?.expiry
        return HStack(alignment: .top, spacing: 14) {
            ModelIconTile {
                Image(systemName: isNew ? "plus" : "pencil").font(.system(size: 14)).foregroundStyle(ModelVisualStyle.accent)
            }
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: Binding(get: { model.draft?.text ?? "" }, set: { model.draft?.text = $0 }))
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 72)
                    .background(ModelVisualStyle.control,
                                in: RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius, style: .continuous)
                        .strokeBorder(ModelVisualStyle.accent.opacity(0.6)))
                    .accessibilityLabel(L(isNew ? "agent.memory.add" : "memory.correct"))
                HStack(spacing: 8) {
                    Text(L("memory.retention")).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                    Picker(L("memory.retention"), selection: Binding(
                        get: { model.draft?.retention ?? .keep }, set: { model.draft?.retention = $0 }
                    )) {
                        if !isNew {
                            Text(L(currentExpiry == nil ? "memory.forever" : "memory.keepRetention"))
                                .tag(AskMemoryNotesSettingsModel.Retention.keep)
                        }
                        if isNew || currentExpiry != nil {
                            Text(L("memory.forever")).tag(AskMemoryNotesSettingsModel.Retention.forever)
                        }
                        Text(L("memory.days7")).tag(AskMemoryNotesSettingsModel.Retention.days(7))
                        Text(L("memory.days30")).tag(AskMemoryNotesSettingsModel.Retention.days(30))
                    }
                    .labelsHidden().frame(width: 150)
                    Spacer()
                    Button(L("memory.cancel")) { model.cancelEditing() }.buttonStyle(ModelActionStyle())
                        .keyboardShortcut(.cancelAction)
                    Button(L(isNew ? "agent.memory.save" : "memory.save")) {
                        model.saveDraft(to: store, owner: owner)
                    }
                    .buttonStyle(ModelActionStyle(primary: true))
                    .disabled(model.draft?.canSave != true)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    static func provenance(_ note: AskMemoryNote) -> String {
        let source = note.provenance?.source == .correction ? L("agent.memory.corrected") : L("agent.memory.explicit")
        let date = note.createdAt.formatted(date: .abbreviated, time: .omitted)
        let retention = note.provenance?.expiry
            .map { L("agent.memory.until", $0.formatted(date: .abbreviated, time: .omitted)) } ?? L("memory.forever")
        return "\(source) · \(date) · \(retention)"
    }
}
