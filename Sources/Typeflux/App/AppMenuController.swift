import AppKit

enum AppMenuController {
    @MainActor
    static func install() {
        NSApp.mainMenu = buildMainMenu()
    }

    @MainActor
    private static func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = buildApplicationMenu()
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = buildEditMenu()
        mainMenu.addItem(editMenuItem)

        return mainMenu
    }

    @MainActor
    private static func buildApplicationMenu() -> NSMenu {
        let menu = NSMenu(title: L("about.appName"))

        let appName = ProcessInfo.processInfo.processName
        let aboutItem = NSMenuItem(title: L("appMenu.about", appName), action: #selector(AppMenuActionRouter.openAbout(_:)), keyEquivalent: "")
        aboutItem.target = AppMenuActionRouter.shared
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: L("appMenu.hide", appName),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h",
        )
        menu.addItem(
            withTitle: L("appMenu.hideOthers"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h",
        ).keyEquivalentModifierMask = [.command, .option]
        menu.addItem(
            withTitle: L("appMenu.showAll"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "",
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: L("appMenu.quit", appName),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q",
        )

        return menu
    }

    @MainActor
    private static func buildEditMenu() -> NSMenu {
        let menu = NSMenu(title: L("appMenu.edit"))

        menu.addItem(withTitle: L("appMenu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: L("appMenu.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: L("appMenu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: L("appMenu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: L("appMenu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: L("appMenu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        return menu
    }
}

@MainActor
private final class AppMenuActionRouter: NSObject {
    static let shared = AppMenuActionRouter()

    @objc func openAbout(_: Any?) {
        AboutWindowController.shared.show()
    }
}
