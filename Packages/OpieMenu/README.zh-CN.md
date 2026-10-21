# OpieMenu

[English](README.md) | **简体中文** · [项目首页](../../README.zh-CN.md)

可单独复制的 macOS Swift Package。它只负责径向菜单的外观、窗口、快捷键和交互；每个按钮做什么，由接入它的应用决定。最低支持 macOS 14；Liquid Glass 样式需要 macOS 26，较早系统会自动使用毛玻璃样式。

## 接入

把整个 `Packages/OpieMenu` 文件夹复制到你的项目中，然后在主项目的 `Package.swift` 中加入：

```swift
dependencies: [.package(path: "Packages/OpieMenu")],
targets: [
    .executableTarget(
        name: "YourApp",
        dependencies: [.product(name: "OpieMenu", package: "OpieMenu")]
    )
]
```

Xcode 工程也可以用 **File → Add Package Dependencies… → Add Local…** 选择该文件夹，并将 `OpieMenu` 产品添加到应用 target。

## 最小用法

在主线程创建并**持有**菜单实例。`onSelect` 会在收起动画完成后调用，适合打开新窗口或执行应用命令。

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

`show(at:)` 接受全局屏幕坐标；省略参数时使用当前鼠标位置。默认快捷键示例为 Control + Option + Space。也可以不注册全局快捷键，直接从应用按钮调用 `show()` 或 `toggle()`。

## 对外接口

| 接口 | 用途 |
| --- | --- |
| `init(items:centerTitle:style:onSelect:)` | 创建菜单，按钮通过稳定且唯一的 `id` 区分；建议放 3–8 个按钮。 |
| `prepare()` | 提前缓存图标和文字，减少首次打开的等待。 |
| `show(at:)`、`toggle(at:)`、`dismiss(completion:)` | 在鼠标位置或指定屏幕点显示、切换、关闭。 |
| `updateItems(_:)`、`setCenterTitle(_:)`、`setStyle(_:)` | 更新按钮、中心标题或风格；显示时也可调用。 |
| `installGlobalHotKey(keyCode:modifiers:)`、`removeGlobalHotKey()` | 可选的全局快捷键；注册函数返回是否成功。 |
| `activatePointedItem()` | 应用自行处理按键松开时，可执行当前鼠标指向的扇区。 |
| `moveSelection(_:)`、`select(index:)`、`activateSelection()` | 应用自行处理键盘时使用。菜单显示期间已经内置方向键、回车、数字键和 Escape。 |
| `isVisible`、`lastPresentationCenter` | 查询窗口状态和最近一次菜单中心的屏幕坐标。 |
| `onWillShow`、`onDismiss`、`onSelect` | 显示前、关闭后、选中后的回调。 |

`OpieMenuIcon` 支持 `.systemSymbol("...")`、`.image(NSImage)` 和 `.smile`。三种 `OpieMenuStyle` 为 `.classic`、`.frosted`、`.liquidGlass`。Package 不会读取或写入宿主应用的偏好设置，也不会执行系统动作。

## 验证

```sh
cd Packages/OpieMenu
swift test
```
