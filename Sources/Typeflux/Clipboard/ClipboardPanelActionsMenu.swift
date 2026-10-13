import AppKit

/// Native menu tracking supplies arrow navigation, Return and Escape without moving list selection.
@MainActor
final class ClipboardPanelActionsMenu: NSObject {
    enum Action {
        case entry(ClipboardEntryAction)
        case togglePause, togglePreview, settings, clearUnpinned
    }

    private weak var model: ClipboardPanelModel?
    private var actions: [Action] = []

    init(model: ClipboardPanelModel) {
        self.model = model
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: L("clipboard.toolbar.more"))
        menu.autoenablesItems = false
        actions = []
        guard let model else { return menu }
        if let entry = model.selectedEntry {
            let entryActions = model.actions(for: entry)
            for (index, action) in entryActions.enumerated() {
                if index > 0, ClipboardPanelRow.startsMenuGroup(action, after: entryActions[index - 1]) {
                    menu.addItem(.separator())
                }
                let item = add(.entry(action), title: action.title(for: entry), to: menu)
                applyShortcut(action, to: item)
                item.isEnabled = model.isEnabled(action, for: entry)
                // Capture identity; an external history update must not redirect an open menu's action.
                item.representedObject = entry.id
            }
            menu.addItem(.separator())
        }
        add(.togglePause, title: L(model.isRecordingPaused ? "clipboard.toolbar.resume" : "clipboard.toolbar.pause"),
            to: menu)
        add(.togglePreview, title: L(model.showsPreview ? "clipboard.menu.hidePreview" : "clipboard.menu.showPreview"),
            to: menu)
        add(.settings, title: L("clipboard.toolbar.settings"), to: menu)
        menu.addItem(.separator())
        add(.clearUnpinned, title: L("clipboard.menu.clearUnpinned"), to: menu)
        return menu
    }

    @discardableResult
    private func add(_ action: Action, title: String, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        actions.append(action)
        menu.addItem(item)
        return item
    }

    private func applyShortcut(_ action: ClipboardEntryAction, to item: NSMenuItem) {
        let shortcut: (String, NSEvent.ModifierFlags)
        switch action {
        case .paste: shortcut = ("\r", [])
        case .pastePlainText: shortcut = ("\r", .command)
        case .editBeforePaste: shortcut = ("e", .command)
        case .copy: shortcut = ("c", .command)
        case .quickLook: shortcut = ("y", .command)
        case .togglePin: shortcut = ("p", .command)
        case .delete: shortcut = ("\u{8}", .command)
        default: return
        }
        item.keyEquivalent = shortcut.0
        item.keyEquivalentModifierMask = shortcut.1
    }

    @objc private func run(_ item: NSMenuItem) {
        guard let model, actions.indices.contains(item.tag) else { return }
        switch actions[item.tag] {
        case let .entry(action):
            guard let id = item.representedObject as? String,
                  let index = model.visibleEntries.firstIndex(where: { $0.id == id }) else { return }
            model.perform(action, at: index)
        case .togglePause: model.send(.togglePause)
        case .togglePreview: model.togglePreview()
        case .settings: model.send(.openSettings)
        case .clearUnpinned: model.requestClearUnpinned()
        }
    }
}
