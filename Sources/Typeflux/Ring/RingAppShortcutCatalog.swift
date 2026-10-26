import AppKit
import Foundation

/// Key combinations worth putting on an app's own ring, for apps Typeflux knows. Offered first in
/// the library while that app's actions are edited.
enum RingAppShortcutCatalog {
    /// One known shortcut: the localized name is `ring.appKeys.<name>`.
    struct Entry: Equatable {
        let name: String
        let keyCode: Int
        let modifiers: NSEvent.ModifierFlags
        let symbol: String

        var binding: HotkeyBinding {
            HotkeyBinding(keyCode: keyCode, modifierFlags: UInt(modifiers.rawValue))
        }

        var title: String {
            L("ring.appKeys." + name)
        }
    }

    private static func entry(_ name: String, _ keyCode: Int, _ modifiers: NSEvent.ModifierFlags,
                              _ symbol: String) -> Entry {
        Entry(name: name, keyCode: keyCode, modifiers: modifiers, symbol: symbol)
    }

    private static let browserTabs: [Entry] = [
        entry("newTab", 17, .command, "plus.square.on.square"),
        entry("reopenTab", 17, [.command, .shift], "arrow.uturn.backward"),
        entry("closeTab", 13, .command, "xmark.square"),
        entry("previousTab", 33, [.command, .shift], "chevron.left"),
        entry("nextTab", 30, [.command, .shift], "chevron.right")
    ]

    /// Bundle identifier → shortcuts, most useful first.
    static let entries: [String: [Entry]] = [
        "com.apple.Safari": [
            browserTabs[0],
            browserTabs[1],
            entry("readerView", 15, [.command, .shift], "doc.plaintext"),
            browserTabs[2],
            entry("showSidebar", 37, [.command, .shift], "sidebar.left"),
            entry("devTools", 34, [.command, .option], "chevron.left.forwardslash.chevron.right"),
            browserTabs[3],
            browserTabs[4],
            entry("history", 16, .command, "clock"),
            entry("readingList", 19, [.control, .command], "eyeglasses")
        ],
        "com.google.Chrome": [browserTabs[0], browserTabs[1], browserTabs[2],
                              entry("devTools", 34, [.command, .option], "chevron.left.forwardslash.chevron.right"),
                              browserTabs[3], browserTabs[4],
                              entry("history", 16, .command, "clock"),
                              entry("bookmarks", 11, [.command, .option], "bookmark")],
        "com.apple.finder": [entry("newWindow", 45, .command, "macwindow.badge.plus"),
                             entry("newFolder", 45, [.command, .shift], "folder.badge.plus"),
                             entry("goToFolder", 5, [.command, .shift], "arrow.right.square"),
                             entry("showHidden", 47, [.command, .shift], "eye"),
                             entry("getInfo", 34, .command, "info.circle"),
                             entry("rename", 36, [], "pencil"),
                             entry("quickLook", 49, [], "eye"),
                             entry("copyPath", 8, [.command, .option], "link")],
        "com.apple.dt.Xcode": [entry("build", 11, .command, "hammer"), entry("run", 15, .command, "play"),
                               entry("stop", 47, .command, "stop"), entry("test", 32, .command, "checkmark.diamond"),
                               entry("openQuickly", 31, [.command, .shift], "magnifyingglass"),
                               entry("toggleComment", 44, .command, "text.quote")],
        "com.microsoft.VSCode": [entry("commandPalette", 35, [.command, .shift], "command"),
                                 entry("quickOpen", 35, .command, "doc.text.magnifyingglass"),
                                 entry("toggleTerminal", 50, .control, "terminal"),
                                 entry("formatDocument", 3, [.option, .shift], "text.alignleft"),
                                 entry("toggleComment", 44, .command, "text.quote"),
                                 entry("findInFiles", 3, [.command, .shift], "magnifyingglass")],
        "com.figma.Desktop": [entry("toggleUI", 42, .command, "rectangle.dashed"),
                              entry("autoLayout", 0, .shift, "rectangle.split.3x1"),
                              entry("export", 14, [.command, .shift], "square.and.arrow.up"),
                              entry("createComponent", 40, [.command, .option], "diamond"),
                              entry("group", 5, .command, "square.on.square")],
        "com.tinyspeck.slackmacgap": [entry("quickSwitcher", 40, .command, "arrow.left.arrow.right"),
                                      entry("allUnreads", 0, [.command, .shift], "tray.full"),
                                      entry("threads", 17, [.command, .shift], "bubble.left.and.bubble.right"),
                                      entry("setStatus", 16, [.command, .shift], "face.smiling")],
        "notion.id": [
            entry("search", 35, .command, "magnifyingglass"),
            entry("newPage", 45, .command, "doc.badge.plus"),
            entry("toggleSidebar", 42, .command, "sidebar.left")
        ],
        "md.obsidian": [entry("newNote", 45, .command, "square.and.pencil"),
                        entry("quickSwitcher", 31, .command, "doc.text.magnifyingglass"),
                        entry("commandPalette", 35, .command, "command"),
                        entry("searchVault", 3, [.command, .shift], "magnifyingglass"),
                        entry("readingView", 14, .command, "doc.plaintext"),
                        entry("findInNote", 3, .command, "text.magnifyingglass")],
        "com.todesktop.230313mzl4w4u92": [
            entry("commandPalette", 35, [.command, .shift], "command"),
            entry("quickOpen", 35, .command, "doc.text.magnifyingglass"),
            entry("toggleTerminal", 50, .control, "terminal"),
            entry("formatDocument", 3, [.option, .shift], "text.alignleft"),
            entry("toggleComment", 44, .command, "text.quote"),
            entry("findInFiles", 3, [.command, .shift], "magnifyingglass")
        ],
        "com.apple.Terminal": [browserTabs[0], entry("clearScreen", 40, .command, "clear"),
                               entry("splitPane", 2, .command, "rectangle.split.2x1")]
    ]

    /// A fresh, bounded starter set. Existing profiles are never silently reseeded.
    static func defaultActions(for bundleIdentifier: String, appName: String) -> [RingAction] {
        items(for: bundleIdentifier, appName: appName).prefix(RingConfiguration.maxActions).map { $0.action() }
    }

    /// Library items for `bundleIdentifier`, listed under "<app> shortcuts". Empty for unknown apps.
    static func items(for bundleIdentifier: String?, appName: String) -> [RingLibraryItem] {
        guard let bundleIdentifier, let list = entries[bundleIdentifier] else { return [] }
        let group = L("ring.library.group.appKeys", appName)
        return list.map { entry in
            RingLibraryItem(kind: .keys(entry.binding), title: entry.title,
                            subtitle: HotkeyFormat.display(entry.binding), symbol: entry.symbol, group: group)
        }
    }
}
