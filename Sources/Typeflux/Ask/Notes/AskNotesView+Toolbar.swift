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
        ToolbarItem(id: "notes.more", placement: .primaryAction) { moreMenu(compact: compact) }
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

    private var compactActions: some View {
        Section {
            ForEach(toolbarGroups.flatMap(\.actions).filter { $0.id != "notes.copy" }) { action in
                Button(role: action.role, action: action.perform) {
                    Label(action.title, systemImage: action.systemImage)
                }
                .disabled(!action.isEnabled)
            }
            if !model.inTrash, !model.selecting {
                Picker(L("ask.notes.edit"), selection: Binding(get: { model.mode }, set: model.setMode)) {
                    ForEach(AskNotesViewModel.Mode.allCases, id: \.self) { mode in
                        Text(L("ask.notes.mode." + mode.rawValue)).tag(mode)
                    }
                }
                .disabled(model.selected == nil)
            }
        }
    }

    private func moreMenu(compact: Bool) -> some View {
        Menu {
            if compact { compactActions }
            if model.inTrash {
                Button(L("ask.notes.trash.empty"), role: .destructive, action: model.emptyTrash)
                    .disabled(model.notes.isEmpty)
            } else {
                Button(L(model.selecting ? "ask.notes.done" : "ask.notes.select")) {
                    model.setSelecting(!model.selecting)
                }
                Button(L("ask.notes.import")) { model.importFiles() }
                Divider()
                Section(L("ask.notes.exportAs")) {
                    Button(L("ask.notes.export.markdown")) { model.exportSelected(.markdown) }
                    Button(L("ask.notes.export.html")) { model.exportSelected(.html) }
                    Button(L("ask.notes.export.pdf")) { model.exportSelected(.pdf) }
                    Toggle(L("ask.notes.export.frontMatter"), isOn: $model.exportOptions.frontMatter)
                    Toggle(L("ask.notes.export.original"), isOn: $model.exportOptions.original)
                }
                .disabled(model.selected == nil || model.selecting)
                Button(L("ask.plugin.action.copyRich"), action: model.copySelectedRich)
                    .disabled(model.selected == nil || model.selecting)
                Button(L("ask.plugin.action.openInWindow"), action: model.openSelectedInWindow)
                    .disabled(model.selected == nil || model.selecting)
                if model.askAI != nil {
                    Button(L("ask.result.askAI"), action: model.askAIAboutSelected)
                        .disabled(model.selected == nil || model.selecting)
                }
                if model.canOpenSource { Button(L("ask.notes.openConversation"), action: model.openSource) }
                if model.agentRevision != nil { Button(L("ask.notes.revertAgent"), action: model.revertAgentChange) }
                Button(L("ask.notes.outline")) {
                    if model.editing {
                        model.setMode(.read)
                        model.showsOutline = true
                    } else {
                        model.showsOutline.toggle()
                    }
                }
                    .disabled(model.selected?.headings.isEmpty != false)
            }
        } label: {
            Label(L("ask.notes.more"), systemImage: "ellipsis").labelStyle(.iconOnly)
        }
        .help(L("ask.notes.more"))
        .accessibilityLabel(L("ask.notes.more"))
        .accessibilityIdentifier("ask.notes.more")
    }
}
