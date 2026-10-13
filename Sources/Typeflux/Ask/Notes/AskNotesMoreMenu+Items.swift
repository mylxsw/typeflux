import AppKit

extension AskNotesMoreMenu.Coordinator {
    func populate(_ menu: NSMenu) {
        let model = self.model
        menu.removeAllItems()
        actions.removeAll()
        let label = NSMenuItem(title: L("ask.notes.more"), action: nil, keyEquivalent: "")
        label.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: L("ask.notes.more"))
        label.isHidden = true
        label.isEnabled = false
        menu.addItem(label)
        label.action = nil
        if compact {
            addCompactActions(to: menu)
            menu.addItem(.separator())
        }
        if model.inTrash {
            add(L("ask.notes.trash.empty"), id: "emptyTrash", to: menu,
                enabled: !model.notes.isEmpty, action: model.emptyTrash)
            return
        }
        add(L(model.selecting ? "ask.notes.done" : "ask.notes.select"), id: "select", to: menu) {
            model.setSelecting(!model.selecting)
        }
        add(L("ask.notes.import"), id: "import", to: menu) { model.importFiles() }
        menu.addItem(.separator())
        addExport(to: menu)
        addDetailActions(to: menu)
    }

    private func addCompactActions(to menu: NSMenu) {
        let model = self.model
        let enabled = model.selected != nil && !model.selecting
        if model.inTrash {
            add(L("ask.notes.trash.restore"), id: "restore", to: menu,
                enabled: enabled, action: model.restoreFromTrash)
            add(L("ask.notes.trash.deleteForever"), id: "deleteForever", to: menu,
                enabled: enabled, action: model.deleteForever)
        } else {
            add(L(model.selected?.pinned == true ? "ask.notes.unpin" : "ask.notes.pin"), id: "pin", to: menu,
                enabled: enabled, action: model.togglePin)
            add(L("ask.notes.delete"), id: "delete", to: menu, enabled: enabled, action: model.deleteSelected)
        }
        menu.addItem(.separator())
        for mode in AskNotesViewModel.Mode.allCases {
            let title = mode == .read ? L("ask.notes.preview") : L("ask.notes.mode." + mode.rawValue)
            add(title, id: "mode." + mode.rawValue, to: menu, enabled: enabled && !model.inTrash,
                checked: model.mode == mode) { model.setMode(mode) }
        }
    }

    private func addExport(to menu: NSMenu) {
        let model = self.model
        let enabled = model.selected != nil && !model.selecting
        let item = NSMenuItem(title: L("ask.notes.exportAs"), action: nil, keyEquivalent: "")
        item.identifier = .init("ask.notes.export")
        item.isEnabled = enabled
        let export = NSMenu()
        export.autoenablesItems = false
        item.submenu = export
        for format in AskNoteExporter.Format.allCases {
            let name = format == .markdown ? "markdown" : format.rawValue
            add(L("ask.notes.export." + name), id: "export." + name, to: export,
                enabled: enabled) { model.exportSelected(format) }
        }
        export.addItem(.separator())
        add(L("ask.notes.export.frontMatter"), id: "export.frontMatter", to: export, enabled: enabled,
            checked: model.exportOptions.frontMatter) { model.exportOptions.frontMatter.toggle() }
        add(L("ask.notes.export.original"), id: "export.original", to: export, enabled: enabled,
            checked: model.exportOptions.original) { model.exportOptions.original.toggle() }
        menu.addItem(item)
        item.action = nil
    }

    private func addDetailActions(to menu: NSMenu) {
        let model = self.model
        let enabled = model.selected != nil && !model.selecting
        add(L("ask.plugin.action.copyRich"), id: "copyRich", to: menu,
            enabled: enabled, action: model.copySelectedRich)
        add(L("ask.plugin.action.openInWindow"), id: "openInWindow", to: menu,
            enabled: enabled, action: model.openSelectedInWindow)
        if model.askAI != nil {
            add(L("ask.result.askAI"), id: "askAI", to: menu, enabled: enabled, action: model.askAIAboutSelected)
        }
        if model.canOpenSource {
            add(L("ask.notes.openConversation"), id: "openSource", to: menu, action: model.openSource)
        }
        if model.agentRevision != nil {
            add(L("ask.notes.revertAgent"), id: "revertAgent", to: menu, action: model.revertAgentChange)
        }
        add(L("ask.notes.outline"), id: "outline", to: menu, enabled: model.selected?.headings.isEmpty == false,
            checked: model.showsOutline) {
            if model.editing {
                guard model.finishEditing() else { return }
                model.showsOutline = true
            } else {
                model.showsOutline.toggle()
            }
        }
    }

    private func add(_ title: String, id: String, to menu: NSMenu, enabled: Bool = true, checked: Bool = false,
                     action: @escaping () -> Void) {
        let id = "ask.notes." + id
        let item = NSMenuItem(title: title, action: #selector(activateItem(_:)), keyEquivalent: "")
        item.identifier = .init(id)
        item.target = self
        item.isEnabled = enabled
        item.state = checked ? .on : .off
        actions[id] = action
        menu.addItem(item)
    }
}
