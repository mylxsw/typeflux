# 圆环（Ring）

> 状态：设计已确认（GUL-448），已实现。可交互设计稿：`docs/design/ring.html`。替换了鼠标语音输入。

> GUL-470：设置页的重新设计（在圆环上直接插入、操作库、即时编辑）见 `ring-studio.md`，待确认。

## 交互

| 手势 | 结果 |
|---|---|
| 按住快捷键（默认 ⌃⌥Space） | 在鼠标位置打开圆环，靠近屏幕边缘时自动内移 |
| 按住 → 移动 → 松开 | 指针离按下点 ≥ 20pt 时执行所指方向的操作；移回中心再松开则取消 |
| 轻按 | 圆环保持打开：点击、`1–8`、方向键 + `↩`；`Esc` 或再按一次快捷键关闭 |

执行在关闭动画之后进行；发送快捷键和表情面板会先把焦点还给原来的应用。录音过程中不响应圆环快捷键。

## 实现

- 圆环组件：`Packages/OpieMenu`（从 opie-menu-macos 引入，见其 README 中的本地改动）。
- 快捷键：`AppHotkeyAction.ring`，由 `SystemHotkeyPool` 同时上报按下和松开；与其他快捷键共用冲突检查，也出现在「设置 → 快捷键」。首次运行时若 ⌃⌥Space 未被占用则自动设置，只设置一次。圆环关闭或没有操作时不注册。
- 配置：`RingConfiguration`，存于 `ring.configuration.json`。最多 8 个操作；读取时跳过无法识别的操作。
- 执行：`RingActionExecutor`。Typeflux 功能和启动器关键词交给 `AppCoordinator` 走与快捷键相同的入口，其余操作通过 `RingSystemEnvironment` 完成。网址只接受 http/https。
- 设置页：`RingSettingsView`，遵循 `settings-search-unification.md`：说明放在悬停问号里，胶囊按钮，Sheet 底部 [取消][添加]，删除与恢复默认先确认。
