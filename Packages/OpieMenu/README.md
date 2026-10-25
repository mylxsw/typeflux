> Vendored into Typeflux from https://github.com/mylxsw/opie-menu-macos at `c2db1d2` (MIT). Local changes: the macOS 13 deployment target Typeflux needs, and `compatibleCGPath` in place of the macOS 14 `NSBezierPath.cgPath`. Typeflux also added pages: `showPage(items:centerTitle:center:)` with an optional centre icon and page dots (`OpieMenuCenter`), `onCenterClick` (a click in the middle or Tab calls it instead of closing), and a short turn-in animation when the page changes.

# OpieMenu

**English** | [简体中文](README.zh-CN.md) · [Project home](../../README.md)

A standalone macOS Swift Package for the radial menu's appearance, floating window, optional global hotkey, and interaction. Your app provides the menu items and decides what each action does. It supports macOS 14 or later. Liquid Glass requires macOS 26 and falls back to Frosted on earlier versions.

## Add the package

Add the repository URL `https://github.com/mylxsw/opie-menu-macos.git` in Xcode and select the `OpieMenu` library product. Alternatively, copy the entire `Packages/OpieMenu` directory into your project and add it as a local package:

```swift
dependencies: [.package(path: "Packages/OpieMenu")],
targets: [
    .executableTarget(
        name: "YourApp",
        dependencies: [.product(name: "OpieMenu", package: "OpieMenu")]
    )
]
```

In an Xcode project, choose **File → Add Package Dependencies… → Add Local…** and select the copied directory.

## Minimal example

Create and retain the menu on the main actor. `onSelect` runs after the closing animation, so it is suitable for opening a window or running an app command.

```swift
import AppKit
import Carbon
import OpieMenu

@MainActor
final class MenuOwner {
    private lazy var menu = OpieRadialMenu(
        items: [
            OpieMenuItem(id: "search", title: "Search", icon: .systemSymbol("magnifyingglass")),
            OpieMenuItem(id: "copy", title: "Copy", icon: .systemSymbol("doc.on.doc")),
            OpieMenuItem(id: "more", title: "More", icon: .systemSymbol("ellipsis"))
        ],
        centerTitle: "Tools",
        style: .frosted
    ) { item in
        switch item.id {
        case "search": print("Open search")
        case "copy": print("Copy")
        default: break
        }
    }

    func start() {
        menu.prepare()
        _ = menu.installGlobalHotKey(keyCode: 49, modifiers: UInt32(controlKey | optionKey))
    }

    func showAtPointer() { menu.show() }
}
```

`show(at:)` accepts a global screen coordinate and uses the current pointer location when omitted. The example shortcut is Control + Option + Space. If your app already handles shortcuts, call `show()` or `toggle()` directly instead.

## Public API

| API | Purpose |
| --- | --- |
| `init(items:centerTitle:style:onSelect:)` | Create a menu with unique, stable item IDs; 3–8 items work best. |
| `prepare()` | Cache icons and text ahead of the first opening. |
| `show(at:)`, `toggle(at:)`, `dismiss(completion:)` | Show at the pointer or a screen point, toggle, or dismiss. |
| `updateItems(_:)`, `setCenterTitle(_:)`, `setStyle(_:)` | Update items, center title, or appearance, even while visible. |
| `installGlobalHotKey(keyCode:modifiers:)`, `removeGlobalHotKey()` | Optionally register a global shortcut; registration returns whether it succeeded. |
| `activatePointedItem()` | Activate the slice under the pointer when your app handles key release itself. |
| `moveSelection(_:)`, `select(index:)`, `activateSelection()` | Control keyboard selection yourself. While open, the menu already handles arrows, Return, number keys, and Escape. |
| `isVisible`, `lastPresentationCenter` | Inspect visibility and the last menu center in screen coordinates. |
| `onWillShow`, `onDismiss`, `onSelect` | Receive presentation and selection callbacks. |

`OpieMenuIcon` supports `.systemSymbol("...")`, `.image(NSImage)`, and `.smile`. The `OpieMenuStyle` cases are `.classic`, `.frosted`, and `.liquidGlass`. The package does not read or write the host app's preferences or run system actions.

## Verify

From the repository root:

```sh
swift test
```

The copied local package can also be tested from `Packages/OpieMenu` with `swift test`.
