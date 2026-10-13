import SwiftUI

extension AskNotesView {
    var toolbarGroups: [TypefluxToolbarGroup] {
        let note = model.selected
        let enabled = note != nil && !model.selecting
        if model.inTrash {
            return [TypefluxToolbarGroup(id: "notes.trash", actions: [
                TypefluxToolbarAction(id: "notes.restore", title: L("ask.notes.trash.restore"),
                                      systemImage: "arrow.uturn.backward", isEnabled: enabled,
                                      perform: model.restoreFromTrash),
                TypefluxToolbarAction(id: "notes.deleteForever", title: L("ask.notes.trash.deleteForever"),
                                      systemImage: "trash", role: .destructive, isEnabled: enabled,
                                      perform: model.deleteForever)
            ])]
        }
        return [TypefluxToolbarGroup(id: "notes.actions", actions: [
            TypefluxToolbarAction(id: "notes.copy", title: L("ask.plugin.action.copy"),
                                  systemImage: "doc.on.doc", isEnabled: enabled, perform: model.copySelected),
            TypefluxToolbarAction(id: "notes.pin", title: L(note?.pinned == true ? "ask.notes.unpin" : "ask.notes.pin"),
                                  systemImage: note?.pinned == true ? "pin.fill" : "pin", isEnabled: enabled,
                                  perform: model.togglePin),
            TypefluxToolbarAction(id: "notes.edit", title: L(model.editing ? "ask.notes.done" : "ask.notes.edit"),
                                  systemImage: model.editing ? "checkmark" : "pencil", isEnabled: enabled,
                                  perform: model.toggleEditing),
            TypefluxToolbarAction(id: "notes.delete", title: L("ask.notes.delete"), systemImage: "trash",
                                  role: .destructive, isEnabled: enabled, perform: model.deleteSelected)
        ])]
    }

    @ToolbarContentBuilder func libraryToolbar(compact: Bool) -> some ToolbarContent {
        if compact, !model.inTrash {
            ToolbarItem(id: "notes.copy", placement: .primaryAction) {
                Button(action: model.copySelected) {
                    Label(L("ask.plugin.action.copy"), systemImage: "doc.on.doc").labelStyle(.iconOnly)
                }
                .disabled(model.selected == nil || model.selecting)
                .help(L("ask.plugin.action.copy"))
                .accessibilityLabel(L("ask.plugin.action.copy"))
                .accessibilityIdentifier("typeflux.toolbar.notes.copy")
            }
        }
        ToolbarItem(placement: .primaryAction) { AskNotesFilterMenu(model: model) }
        ToolbarItem(id: "notes.more", placement: .primaryAction) {
            AskNotesMoreMenu(model: model, compact: compact)
                .frame(width: 32, height: 28)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L("ask.notes.more"))
                .accessibilityIdentifier(AskNotesMoreMenu.accessibilityIdentifier)
        }
        if !compact, model.selected != nil, !model.inTrash, !model.selecting {
            ToolbarItem(placement: .principal) {
                Picker("", selection: Binding(get: { model.mode }, set: model.setMode)) {
                    ForEach(AskNotesViewModel.Mode.allCases, id: \.self) { mode in
                        Text(L("ask.notes.mode." + mode.rawValue)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityLabel(L("ask.notes.edit"))
                .accessibilityIdentifier("ask.notes.mode")
            }
        }
    }

}
