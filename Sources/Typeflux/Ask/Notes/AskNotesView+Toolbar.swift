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
            TypefluxToolbarAction(id: "notes.share", title: L("ask.notes.share"),
                                  systemImage: "square.and.arrow.up", isEnabled: enabled && model.sharingText != nil,
                                  sharingText: model.sharingText, perform: {}),
            TypefluxToolbarAction(id: "notes.delete", title: L("ask.notes.delete"), systemImage: "trash",
                                  role: .destructive, isEnabled: enabled, perform: model.deleteSelected)
        ])]
    }

    func visibleToolbarGroups(compact: Bool) -> [TypefluxToolbarGroup] {
        guard compact else { return toolbarGroups }
        // Keep copy available while the remaining actions stay in the native More menu.
        return toolbarGroups.map { group in
            TypefluxToolbarGroup(id: group.id, actions: group.actions.filter { $0.id == "notes.copy" })
        }
    }

    func toolbarAccessories(compact: Bool) -> some View {
        HStack(spacing: TypefluxSpacing.compact.value(for: style)) {
            if !compact { AskNotesFilterMenu(model: model) }
            AskNotesMoreMenu(model: model, compact: true)
                .frame(width: TypefluxControlWidth.toolbarItem.value(for: style),
                       height: TypefluxControlHeight.toolbarItem.value(for: style))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L("ask.notes.more"))
                .accessibilityIdentifier(AskNotesMoreMenu.accessibilityIdentifier)
        }
    }
}
