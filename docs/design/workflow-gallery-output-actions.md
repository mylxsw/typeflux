# 工作流：示例库、每个关键字的入口、输出与动作

> 状态：O1（GUL-230）、O2（GUL-231）已实现，见第 6、7 节。
> 可交互设计稿：`docs/design/workflow-gallery-output-actions.html`（`?solo=<id>` 单独看一屏，`?light=1` 浅色），截图在 `docs/design/workflow-gallery-output-actions/`。
> 基于已经上线的工作流 W1（`ask-launcher-workflows.md`）和编辑器（`ask-workflow-editor.md`、`launcher-keywords-workflow-editor.md`）。

## 0. 一页结论

| 问题 | 方案 |
|---|---|
| 新用户不知道工作流能做什么，也没有能直接用的 | **示例库**：随应用提供 8 个示例，卡片浏览、看详情、一键添加。添加 = 复制一份到自己的工作流目录，记为已信任，之后随便改。 |
| 入口看起来只能是 `main.py`；额外的脚本不知道怎么用 | 入口本来就可以是任何文件（`command.script`）；额外的脚本可以被入口引用（工作目录就是工作流文件夹）。新增**每个关键字可以有自己的入口**（`keywords[].script`），编辑器标出哪个文件是入口，出错定位支持所有文件。 |
| 输出只能显示文本 | 输出拆成两部分，**都在图形界面里配置**：**怎么显示**（文本 / 不显示 / 条目列表 / Markdown / 图片）+ **运行成功后、失败后执行的动作**（复制、写回、通知、底栏提示、打开、在 Finder 中显示、朗读、交给 AI、运行另一个关键字）。动作内容用占位符（`{output}`、`{json.字段}`…）。脚本也可以在运行时追加动作，但要在界面上打开开关。 |

分四步做：**O1** 输出配置和动作；**O2** 示例库 + 每个关键字的入口；**O3** 条目列表、Markdown；**O4** 脚本追加动作、图片、运行另一个关键字。

## 1. 示例库（截图 ①②）

### 1.1 入口

- 编辑器左下角「＋ 新建工作流」菜单：用 AI 生成 / **从示例库添加** / 从模板开始。
- 设置 → 启动器 → 启动器工作流：列表上方「示例库」按钮；没有工作流时空状态直接展示前 3 个示例。

### 1.2 界面

- 一个大的对话框（980×640）：左边是类别（全部 / 文本处理 / 开发 / 网络 / 系统，带数量）和搜索，右边是卡片网格。
- **卡片**：图标、名称、一句话说明、关键字、运行时、权限标签（「联网」用橙色），右下角「添加」或「已添加」。
- **详情**（点卡片进入）：
  - 基本信息：关键字（冲突时说明会改名）、运行时（说明系统自带，不需要装依赖）、**会做什么**（联网地址、复制、通知等，来自第 3 节的动作配置和风险扫描）、演示了哪些用法、文件列表。
  - 用法（README.md）。
  - 启动器里的样子（示例自带的一次输出）和入口脚本的前 20 行。
  - 按钮：「添加到我的工作流」；已添加时变成「在编辑器中打开」。

### 1.3 添加的语义

- **复制**示例文件夹到 `~/Library/Application Support/Typeflux/Workflows/<id>/`，id 用示例的 id（`local.fx`），已存在时加后缀（`local.fx-2`）。
- **关键字冲突**：和内置关键字、其他工作流重名时自动加数字后缀（`fx2`），添加后底栏提示一次。复用 `AskWorkflowStore.create` 的查重逻辑。
- **信任**：示例随应用签名发布，添加时直接记录为已信任（和用模板创建一样）。
- **来源**：清单里写 `"origin": {"gallery": "fx", "version": "1.0.0"}`，编辑器标题下显示「来自示例库」。
- **更新**：应用里的示例版本更新后，示例库卡片显示「有新版本」；点「查看更新」用现有的差异视图对比「我的版本 / 新版本」，用户确认后才覆盖（覆盖后仍是已信任）。用户改过的文件在差异里标出来。**从不自动覆盖。**
- 删除示例添加的工作流和删除普通工作流一样；示例库里重新变成「添加」。

### 1.4 打包

- 示例放在应用资源里：`Sources/Typeflux/WorkflowGallery/<id>/`（`workflow.json`、脚本、`README.md`），整个文件夹原样复制进资源包（O2 实现时从 `Resources/` 挪出来：`Resources` 按 `.process` 处理会把子目录拍平）。
- 新增 `gallery.json` 索引：id、类别、排序、示例输出（详情页的预览用，不需要运行）。
- 加载走 `Bundle.appResources`；示例本身也用 `AskWorkflowManifest.problems` 校验，单测保证每个示例都是有效的清单、关键字互不冲突、脚本能跑通（见第 6 节）。

### 1.5 首批示例

只用 macOS 自带的 Python 3 / Node / zsh，不需要安装依赖。Node 不一定装了：没有时卡片上显示「需要 Node」，添加按钮旁边给出安装说明。

| 示例 | 关键字 | 运行时 | 显示 / 动作 | 演示了什么 |
|---|---|---|---|---|
| 汇率换算 | `fx`、`rate` | Python | 文本；复制第一行 + 通知 | 联网（`open.er-api.com`）、参数解析、**两个关键字两个入口**（`rate` → `table.py`）、预设参数 `to=usd,eur,jpy` |
| 时间戳转换 | `ts` | Python | 文本 | 没参数时用选中的文字、多行输出 |
| JSON 格式化 | `json` | Python | 文本；写回 | 处理选中的文字、写回动作 |
| URL / Base64 编解码 | `url`、`b64` | Node | 文本 | 一个工作流多个关键字，用预设参数区分编码 / 解码 |
| 生成 UUID / 密码 | `uuid`、`pwd` | zsh | 不显示；复制 + 底栏提示 | 「只做事」的工作流 |
| 本机 IP | `ip` | zsh | 条目列表 | 列表，选一条复制（O3 之后才放进示例库） |
| 字数统计 | `wc` | Python | 文本 | 最简单的入门示例 |
| 在编辑器打开项目 | `code` | zsh | 条目列表；打开 | 列表 + 打开应用（O3 之后） |

## 2. 入口和多个文件（截图 ③）

### 2.1 现在已经可以

- 入口是清单的 `command.script`，可以是文件夹里的任何文件（编辑器：脚本 → 运行设置 → 脚本）。
- 运行时的工作目录是工作流文件夹，另有环境变量 `TYPEFLUX_WORKFLOW_DIR`。所以入口可以直接引用其他文件：Python `import helper`（脚本所在目录在 `sys.path` 里）、Node `require('./helper')`、zsh `source ./lib.sh`、`subprocess.run(["./tool"])`。

### 2.2 新增：每个关键字的入口

```json
"command": { "runtime": "python3", "script": "main.py", "args": ["{query}"] },
"keywords": [
  { "keyword": "fx", "title": "汇率" },
  { "keyword": "rate", "title": "汇率表", "script": "table.py", "options": { "to": "usd,eur,jpy" } }
]
```

- `keywords[].script` 可选；有就覆盖 `command.script`，没有就用默认入口。运行时、参数模板、解释器仍然是工作流级别的（同一个工作流用同一种运行时）。
- 校验：文件必须存在、在工作流文件夹内、不是 `workflow.json`；用了 `command.inline` 的工作流不能再给关键字指定入口。问题字段是 `keywords[1].script`，归到「关键字」步骤。
- 信任：入口文件本来就包含在内容哈希里，不变。
- 运行器：`AskWorkflowPlugin.invocation` 按 `request.keyword` 找到这个关键字的入口。
- 测试面板：选了哪个关键字，就运行哪个入口。

### 2.3 编辑器

- 关键字表多一列「入口」：下拉选择文件夹里同运行时的脚本，第一项是「默认（main.py）」。
- 「关键字」步骤下面新增「文件」卡片：每个文件一行，入口文件标「入口 · fx」；其他文件写一句怎么被引用（简单的静态扫描：Python `import x`、Node `require('./x')`、shell `source ./x`，扫不到就不写）。
- 脚本步骤的文件标签上，入口文件带一个小标记。
- **出错定位支持所有文件**：`AskWorkflowStderrLocator.locate` 的 `files` 改为工作流里的全部文本文件（现在只传入口），stderr 指向 `rates.py:12` 时也能跳过去并标红。

## 3. 输出与动作（截图 ④–⑨）

### 3.1 清单格式

```json
"output": {
  "display": "text",
  "onSuccess": [
    { "action": "copy", "value": "{output.line1}" },
    { "action": "notify", "title": "汇率换算", "body": "{output}" }
  ],
  "onFailure": [
    { "action": "notify", "title": "汇率换算失败", "body": "{error}" }
  ],
  "close": false,
  "scriptActions": false
}
```

- 兼容：字符串写法 `"output": "text" | "none" | "auto" | "items"` 继续有效，读取时等于 `{"display": …}`；编辑器写回时只在用户加了动作或改了开关后才换成对象写法，不打乱旧清单。
- `display`：`text`（默认）、`none`、`auto`、`items`、`markdown`、`image`。
- `close`：动作执行完关闭启动器。`display: none` 时总是关闭（和现在一样），界面上开关锁定为开。
- `scriptActions`：允许脚本追加动作（3.6），默认 `false`。
- 动作数组最多 8 个；不认识的 `action` 是校验问题（不是静默忽略），提示「这个版本的 Typeflux 不支持」。

### 3.2 怎么显示

| 值 | 启动器里 | 默认的 ↩ / ⌥↩ |
|---|---|---|
| `text` | 文本卡片（现在的样子） | 复制 / 写回 |
| `none` | 不显示，运行完关闭；失败时显示错误卡片（除非配置了失败动作） | — |
| `auto` | stdout 是 `{"items": …}` 时按列表，否则按文本 | 同对应类型 |
| `items` | 条目列表（`ask-launcher-workflows.md` §4.2，兼容 Alfred Script Filter） | 由每条的 `action` / `mods` 决定 |
| `markdown` | Markdown 卡片：标题、列表、表格、代码块、链接（复用 Ask 的 Markdown 渲染） | 复制原文 / 写回原文 |
| `image` | 图片卡片：stdout 是图片文件路径（相对工作流文件夹或绝对路径）或 `data:image/png;base64,…` | 复制图片 / 在 Finder 中显示 |

### 3.3 动作

| 动作 | 字段 | 行为 | 现有实现 |
|---|---|---|---|
| `copy` 复制到剪切板 | `value` | 写入剪切板；底栏「已复制」，⌘Z 恢复之前的剪切板内容（只在启动器还开着时） | `AskPluginAction.copy` |
| `writeBack` 写回 / 替换选中的文字 | `value` | 有选中文字时替换，否则插入到光标处；启动器先关闭再写回 | `.writeBack` |
| `notify` 发送通知 | `title`、`body` | 系统通知；首次使用时请求权限，被拒绝时退回底栏提示并在测试面板说明 | `LocalNotificationService` |
| `hud` 底栏提示 | `text` | 启动器底栏一行；启动器已关闭时用一个 2 秒的小浮层 | 底栏已有「已完成」 |
| `open` 打开 | `target` | http(s) 链接、文件（相对工作流文件夹或 `~`）、`app:` 应用名或 bundle id；其他 scheme 拒绝 | `.open(URL)` |
| `reveal` 在 Finder 中显示 | `path` | `activateFileViewerSelecting` | 新增，很小 |
| `speak` 朗读 | `text`、`language`（可选） | 系统 TTS | `.speak` |
| `askAI` 交给 AI | `prompt` | 打开随便问，带着结果继续问 | `.askAI` |
| `runKeyword` 运行另一个关键字 | `keyword`、`argument` | 把「关键字 + 参数」填进启动器并运行；最多串 3 层，环检测 | 新增（O4） |

**执行规则**

- 按顺序执行。前一个失败（例如通知权限被拒）不影响后面的，失败原因记进运行日志和测试面板。
- 时机：结果显示出来之后立即执行；`writeBack` 和 `open` 会关闭启动器，所以它们之后的动作仍会执行，但不再有底栏，改用浮层提示。
- 动作和用户按的快捷键不冲突：↩ / ⌥↩ 仍然可以再复制、写回一次。
- 底栏汇总：「✓ 已复制「100 USD = 14,912.30 JPY」· ✓ 已发送通知」（截图 ⑨）。
- 失败动作在脚本退出码非 0、超时或输出过长被截断时执行；`{error}` 是错误原因 + stderr 最后几行。

### 3.4 占位符

| 占位符 | 含义 |
|---|---|
| `{output}` | 去掉首尾空白的完整 stdout |
| `{output.line1}`、`{output.lastLine}` | 第一行、最后一行 |
| `{json.a.b}` | stdout 是 JSON 时取字段（点号路径，数组用 `{json.items.0.title}`）；取不到时为空，并在测试面板提示 |
| `{query}`、`{selection}`、`{keyword}`、`{option:名字}` | 和参数模板一样 |
| `{error}` | 只在失败动作里可用 |

- 替换是纯文本，不做 shell 求值。用在 `open` 的 URL 里时，**自动对插入的值做 URL 编码**（只编码占位符的值，不编码用户写的固定部分）。
- 编辑器里占位符显示成小标签，「{ } 插入」菜单列出所有占位符和用上次测试运行算出的值（截图 ⑥）；输入 `{` 也会弹出这个菜单。

### 3.5 编辑器「输出」步骤（截图 ④⑤⑥⑦）

- 左列：
  - 「怎么显示」单选列表。
  - 「运行成功后」动作列表：每行包括拖动手柄、动作图标和名称、需要权限时的提示、字段（占位符输入框）、删除按钮；最后一行「＋ 添加动作」，菜单分为常用 / 打开 / 更多三组。
  - 「运行失败后」动作列表，结构相同。
  - 两个开关：「执行完关闭启动器」「允许脚本追加动作」。
- 右列：「启动器里的样子」随显示方式变化（条目列表就是可选择的列表）。下面「这次运行成功后会执行」列出每个动作和替换后的值。
- 步骤条摘要：「文本 · 2 个动作」。
- 清单里的 `output` 和表单双向同步；校验问题（未知动作、缺字段、`open` 的地址无效、`reveal` 指向工作流外且不是 `~`）标在对应的行。

### 3.6 脚本追加动作（O4）

stdout 是下面这样的 JSON 时，启动器把 `text` 当作显示内容，把 `actions` 当作追加动作：

```json
{ "text": "100 USD = 14,912.30 JPY", "actions": [ { "action": "open", "target": "https://www.xe.com/…" } ] }
```

- 只有打开了「允许脚本追加动作」才执行；没打开时测试面板列出来，标「未执行：未允许脚本追加」（截图 ⑧）。
- 追加动作在配置的动作之后执行，同样受 8 个上限和动作白名单约束。
- 追加的 `open` / `writeBack` 遵守风险规则：**新出现的网络地址**和清单 / 脚本里没有的地址，第一次执行前在启动器里确认一次（「汇率换算想打开 xe.com，允许吗？」），确认结果按工作流 + 域名记住。

### 3.7 测试运行（截图 ⑧）

- 结果分段多一个「动作 N」。
- 「只预览动作，不真的执行」默认勾选：列出每个动作和替换后的值，不执行。取消勾选后真的执行；`writeBack`、`open`、`runKeyword` 执行前仍然确认一次，避免测试时误操作其他应用。
- 失败动作也能测：测试输入导致失败时列出失败动作。

### 3.8 信任和安全

- 动作配置在 `workflow.json` 里，属于内容哈希，改了就要重新信任（编辑器里保存时自动更新信任，规则不变）。
- 风险扫描（`AskWorkflowRiskScanner`）把动作也算进去：`open` 外部地址算联网，`writeBack` 算「写入其他应用」，在信任面板和 AI 提案里显示。
- 不提供执行任意命令的动作：要执行命令就写在脚本里。

## 4. 实现计划

| 阶段 | 内容 | 主要改动 |
|---|---|---|
| **O1 输出配置和动作** | `output` 对象写法和兼容解码；动作：copy / writeBack / notify / hud / open / reveal / speak / askAI；占位符引擎；成功 / 失败动作；close；编辑器「输出」步骤（动作列表、添加菜单、占位符输入框、预览、这次会执行）；测试面板「动作」分段和只预览；底栏汇总和 ⌘Z 撤销复制；风险扫描 | `AskWorkflowManifest`（`Output` → struct）、新 `AskWorkflowAction`、`AskWorkflowPlaceholders`、`AskWorkflowPlugin.finish`、`AskWorkflowEditorForms`（输出）、`AskWorkflowEditorPanels`、`AskWorkflowRiskScanner` |
| **O2 示例库 + 每个关键字的入口** | 资源目录和 `gallery.json`；示例库对话框和详情；添加 / 更新；首批 6 个示例（除了需要列表的两个）；`keywords[].script`；文件卡片；出错定位支持所有文件 | 新 `AskWorkflowGallery`、`AskWorkflowGallerySheet`；`AskWorkflowPlugin.invocation`；`AskWorkflowKeywordsForm`；`AskWorkflowStderrLocator` 调用处 |
| **O3 条目列表和 Markdown** | 原 W2 的条目列表（视图、条目动作、Alfred 兼容）；Markdown 卡片；「本机 IP」「打开项目」两个示例 | `AskWorkflowPlugin`、启动器结果视图 |
| **O4 脚本追加动作、图片、运行另一个关键字** | `scriptActions` 和确认；图片卡片；`runKeyword` 和环检测 | 同上 |

**测试**（每阶段覆盖率按项目要求）：

- 解码兼容：旧字符串写法、对象写法、未知动作。
- 占位符：每种占位符、JSON 路径、URL 编码、取不到时为空。
- 动作执行：顺序、失败不影响后续、权限被拒时退回、close 的组合。
- 示例：每个示例都是有效清单、关键字不冲突、用测试输入跑通（CI 上没有 Node 时跳过 Node 示例）。
- 添加 / 冲突改名 / 更新差异。
- 每个关键字的入口：invocation 选对脚本，校验问题，出错定位到非入口文件。
- 编辑器和示例库渲染快照（和本次一样写到 `docs/design/workflow-gallery-output-actions/implemented-*`）。

## 5. 需要确认

1. 输出的 `output` 对象格式（3.1），尤其是 `onSuccess` / `onFailure` 两个列表和 `scriptActions` 默认关闭。
2. 测试运行默认「只预览动作」，你是否希望默认真的执行？
3. 示例库首批 8 个是否合适，要不要加别的（例如「翻译到剪切板」「Markdown 转 HTML」「二维码」）？
4. 示例更新只提示、不自动覆盖，可以吗？

## 6. O1 实现说明（GUL-230）

**已实现**：3.1–3.5、3.7、3.8。显示方式只开放 `text` / `none` / `auto`，`items` / `markdown` / `image` 在单选列表里显示为「即将支持」，写进清单时是校验问题；`scriptActions` 字段能读写，开关可用，但要到 O4 才生效。

| 部分 | 代码 |
|---|---|
| `output` 对象写法和兼容解码、校验 | `AskWorkflowOutput.swift`、`AskWorkflowAction.swift` |
| 占位符（含 JSON 路径、链接里的 URL 编码） | `AskWorkflowPlaceholders.swift` |
| 动作的填值、执行顺序、权限回退、汇总 | `AskWorkflowActionRunner.swift` |
| 运行后带上成功 / 失败动作 | `AskWorkflowPlugin.finish` |
| 启动器执行动作、底栏汇总、⌘Z 撤销复制、关闭后的小浮层 | `AskConversationModel+WorkflowActions.swift`、`AskWorkflowActionsSummaryView`、`AskWorkflowNoticePanel` |
| 编辑器「输出」步骤 | `AskWorkflowOutputForm.swift`、`AskWorkflowEditorModel+Output.swift` |
| 测试运行的「动作」分段和只预览 | `AskWorkflowTester`、`AskWorkflowTestActions` |
| 风险扫描、信任面板 | `AskWorkflowRiskScanner.scanActions`（`open` 网址算联网，`writeBack` 算「写入其他应用」）、`AskWorkflowTrustSummary.actions` |

**实现细节**：

- 编辑器改动 `output` 时：原来是字符串、只改显示方式，仍写字符串；加了动作或打开开关才换成对象；原来就是对象的保持对象。空的动作列表和关掉的开关不写进清单。
- 占位符一次替换，替换进来的文字不会再被展开。`open` 只对 http(s) 链接里、固定前缀之后的值做 URL 编码；整个地址就是一个占位符时（`{output}` 本身是链接）不编码。
- 校验只检查能静态判断的部分：`open` 的固定部分只能是 http(s)、`app:`、`file:` 或路径；`reveal` 的路径要在工作流文件夹里或以 `~` 开头；`{error}` 只能用在失败动作里。占位符替换后的值在运行时再检查，不符合的那一步记为失败，后面的照常执行。
- 输出被截断也执行失败动作，`{error}` 是「输出过长被截断」；显示方式为 `none` 且配置了失败动作时，失败后不显示错误卡片，执行完关闭。
- 通知权限被拒或发送失败时，内容改用底栏提示，汇总写「✓ 标题 · 内容（通知未开启，改为底栏提示）」。
- 写回、打开、交给 AI 会关闭启动器；之后的底栏提示改用屏幕下方 2 秒的小浮层。
- ⌘Z 撤销复制：恢复复制前剪切板的全部内容（所有类型），只在这次结果还显示着时有效，只能撤销一次；其余时候 ⌘Z 仍是输入框自己的撤销。
- 测试运行里「交给 AI」不执行（标「测试运行不执行」）；写回没有目标应用，确认后改为复制到剪切板并在编辑器顶部说明。
- 顺手修了一个旧问题：参数模板里有未闭合的 `{` 时，它前面那段文字会重复一遍（`"a {query} x{b"` 得到 `"a q x x{b"`，应为 `"a q x{b"`）。

### 逐屏对照

截图由 `WorkflowOutputActionsVisualTests` 用真实视图渲染（`TYPEFLUX_ASK_SNAPSHOTS=<目录> swift test --filter WorkflowOutputActionsVisualTests`），在 `workflow-gallery-output-actions/implemented-*`。

| 设计稿 | 实现 | 对照结果 |
|---|---|---|
| ④ `ed-output.png` | `implemented-ed-output(-light).png` | 一致：显示方式单选、成功 / 失败两个列表、拖动手柄、通知的权限提示、占位符小标签和「{ } 插入」、两个开关、启动器预览、「这次运行成功后会执行」、步骤条「文本 · 2 个动作」。 |
| ⑤ `ed-add.png` | `implemented-ed-add(-light).png` | 一致：常用 / 打开 / 更多三组，每项写出要填的字段。没有「运行另一个关键字」（O4）。 |
| ⑥ `ed-token.png` | `implemented-ed-token(-light).png` | 一致：标题、每个占位符的说明和上次测试运行的值。菜单向上展开，避免靠下的行被滚动区域裁掉。 |
| ⑧ `ed-test.png` | `implemented-ed-test(-light).png` | 一致：「只预览动作，不真的执行」默认勾选，分段里有「动作 2」，每个动作标「预览」。没有「脚本追加」那一行（O4）。 |
| ⑨ `launcher.png` | `implemented-launcher(-light).png` | 一致：卡片照常显示，底栏「✓ 已复制「…」 · ✓ 已发送通知」，右侧「按 ⌘Z 撤销复制」。 |
| — | `implemented-ed-output-none.png` | 「不显示，只做事」：「执行完关闭启动器」锁定为开，预览显示「已完成，启动器关闭」，失败动作里的无效地址标在状态栏。 |

和设计稿的差异：测试面板保留了原有的「传入了什么」分段，所以是五个分段；显示方式列表多一个「自动判断」（O1 范围内）。

## 7. O2 实现说明（GUL-231）

**已实现**：第 1 节（示例库，首批 6 个示例）、第 2 节（每个关键字的入口、文件卡片、出错定位支持所有文件）。「本机 IP」「在编辑器打开项目」需要条目列表，等 O3。

| 部分 | 代码 |
|---|---|
| 示例和索引 | `Sources/Typeflux/WorkflowGallery/`：`gallery.json` + `fx`、`ts`、`json`、`codec`、`uuid`、`wc` 六个文件夹 |
| 读取示例、本地化、生成要写的文件、版本比较、联网地址 | `AskWorkflowGallery.swift` |
| 添加（改名、信任、`origin`）、查看更新、覆盖 | `AskWorkflowStore+Gallery.swift` |
| 示例库对话框、详情、更新差异；设置页空状态 | `AskWorkflowGallerySheet.swift`（`AskWorkflowGalleryStarter`） |
| `keywords[].script`：选入口、校验 | `AskWorkflowManifest`（`script(forKeyword:)`、`entryScripts`、`keywordScriptProblems`）、`AskWorkflowPlugin.invocation` |
| 入口列、文件卡片、文件标签上的入口标记 | `AskWorkflowKeywordsForm.entryPicker`、`AskWorkflowFilesCard`、`AskWorkflowFileReferences`、`AskWorkflowEditorModel+Files` |
| 出错定位支持所有文件 | `AskWorkflowStderrLocator.files(in:)`，`AskWorkflowPlugin.editActions` 改用它（编辑器原本就传全部文件） |

**实现细节**：

- **打包**：示例放在 `Sources/Typeflux/WorkflowGallery/`，用 `.copy` 原样进资源包。放在 `Resources/` 下不行：`Resources` 是 `.process`，会把子目录拍平，而且 SwiftPM 不允许在它里面再套一条 `.copy` 规则。
- **多语言**：示例清单里要翻译的文字写成 `"@L:fx.name"`，读取和添加时换成当前界面语言的文案（键在 `ask.workflow.gallery.*`）。所以添加后的名称、关键字显示名称、通知标题是用户当时的语言。脚本和 `README.md` 是英文。
- **添加**：id 用清单里的 `local.<id>`，被占用时加 `-2`、`-3`；关键字和内置关键字、其他工作流重名时加数字（`fx` → `fx2`），对话框左下角说明改了哪些。写入后按内容哈希记为已信任，清单里写 `origin`，同时把每个文件的哈希记在设置里（`ask.workflows.galleryBaseline`），用来判断用户改过哪些文件。
- **更新**：示例库里的版本比 `origin.version` 新时，卡片显示「查看更新」。差异视图对比「我的版本 / 新版本」，新版本沿用用户现在的 id 和关键字（数量变了才用示例的），用户改过的文件在标签上标橙点，并在上方写出来。点「覆盖为新版本」才写入：旧版本有、新版本没有的文件删掉，用户自己加的文件保留，覆盖后仍是已信任。
- **复制**一个来自示例库的工作流时去掉 `origin`：复制出来的是用户自己的工作流。删除、改 id 时同步清掉 / 迁移文件哈希记录。
- **入口**：`keywords[].script` 覆盖 `command.script`；运行时、参数模板、解释器仍是工作流级别的。校验：文件要存在、在文件夹里、不是 `workflow.json`，`exec` 运行时还要可执行；用了 `command.inline` 时不能指定。编辑器里还没保存的文件算存在。保存时所有入口脚本都会设为可执行。
- **入口下拉**：第一项「默认（main.py）」，其余是文件夹里同一种语言的脚本（`exec` 运行时列出所有文件）。选回默认入口时，清单里的 `script` 字段会删掉。
- **文件卡片**：入口标「入口 · 关键字」；其他文件用简单扫描写出被谁引用：Python 的 `import x` / `from x import`，Node 的 `require('./x')` / `import … from './x'`，shell 的 `source ./x` / `. ./x`。扫不到就不写，`.md` 写「说明文件」。
- **出错定位**：启动器出错时，⌘E 能跳到工作流里任何文件的那一行（例如 `rates.py:12`），不再只认默认入口。只在 stderr 不为空时扫描文件夹。
- **示例的运行时**：Node 不一定装了：示例库在后台查一次 PATH，没有时卡片显示「需要 Node」，详情页写出安装命令（`brew install node`）。
- AI 生成工作流时用的说明（`AskWorkflowAuthorSkill`）也加上了 `keywords[].script`。

### 逐屏对照

截图由 `WorkflowGalleryVisualTests` 用真实视图渲染（`TYPEFLUX_ASK_SNAPSHOTS=<目录> swift test --filter WorkflowGalleryVisualTests`）。

| 设计稿 | 实现 | 对照结果 |
|---|---|---|
| ① `g-list.png` | `implemented-g-list(-light).png` | 一致：左侧类别（带数量）和搜索，右侧三列卡片：图标、名称、一句话说明、关键字、运行时、「联网」橙色标签，「添加」/「已添加」。只显示有示例的类别（「系统」等 O3 才有示例）。 |
| ② `g-detail.png` | `implemented-g-detail(-light).png` | 一致：返回链接、大图标和说明、「已添加」+「在编辑器中打开」；基本信息（关键字和改名说明、运行时、会做什么、演示了、文件）、用法、启动器里的样子、入口脚本前 20 行（不含 `#!` 行，不自动换行）。 |
| ③ `ed-entry.png` | `implemented-ed-entry(-light).png` | 一致：关键字表多了「入口」列，「文件」卡片标出入口和引用关系，标题下「来自示例库」。 |
| — | `implemented-g-update.png`、`implemented-g-list-update.png` | 查看更新：版本号、用户改过的文件、差异视图和「覆盖为新版本」。 |
| — | `implemented-g-detail-node.png`、`implemented-g-list-node.png` | 没有 Node 时的标签和安装说明。 |
| — | `implemented-ed-entry-tabs.png`、`implemented-ed-entry-problem.png` | 脚本步骤的文件标签：入口排在前面并带标记；入口文件不存在时标在那一行。 |
| — | `implemented-settings-empty(-light).png` | 设置页没有工作流时，直接展示前 3 个示例，可以一键添加。 |

对照时发现并修了这些问题：对话框背景半透明（截图里透出编辑器）；卡片底部放不下，「Python」被折成两行，「联网」「已添加」被截断；名称「URL / Base64 编解码」被截断（左栏比设计稿宽，改为 230pt）；入口脚本预览自动换行；「入口」下拉没有边框；文件卡片说明的句号落到下一行开头；更新页的按钮挤压了文件标签；没有动作的示例「会做什么」是空的。

和设计稿的差异：详情页「用法」来自 `gallery.json` 里多语言的用法列表，不是直接显示 `README.md`（`README.md` 是英文，仍随示例一起复制）；编辑器左上角工作流图标的颜色仍按 id 计算，不用示例的颜色。

## 8. O3 实现说明（GUL-232）

**已实现**：3.2 里的 `items`、`markdown` 两种显示方式（`auto` 也会按列表显示），条目动作、Alfred 兼容字段、`rerun`、`variables`；编辑器「输出」步骤的预览随显示方式变化（截图 ⑦）；示例库加上「本机 IP」「在编辑器打开项目」。`image` 仍是「即将支持」（O4）。

| 部分 | 代码 |
|---|---|
| 解析 `{"items": …}`（Alfred Script Filter）、按显示方式解码 | `AskWorkflowItems.swift`（`AskWorkflowItemList`、`AskWorkflowDecodedOutput`） |
| 条目 → 启动器的行：每个键做什么、图标、路径 | `AskWorkflowItemRows.swift`（启动器和编辑器预览共用） |
| 运行后按显示方式出结果；列表不流式显示 | `AskWorkflowPlugin.finish` / `run` |
| 结果里的条目、选中的行、`rerun`、`variables` | `AskPluginOutput.items` / `selectedItem` / `rerunAfter` / `variables`，`AskPluginItem` |
| 上下选择、定时重跑、`variables` 作为下次的参数 | `AskPluginSession.moveSelection` / `selectItem` / `scheduleRerun` / `adopt` |
| 键盘：↑↓、⇥ 补全、↩ / ⌥↩ / ⌘C / ⌘↩ | `AskComposerViews.pluginKey`、`AskConversationModel.performPluginAction`（新增 `.openIn`、`.reveal`、`.runWith`） |
| 列表和 Markdown 的卡片 | `AskPluginViews`（`itemList`、`markdownHeight`）、`AskPluginItemViews.swift` |
| 编辑器预览、示例库详情的预览 | `AskWorkflowLauncherPreview`（`decoded`、示例列表 / Markdown） |
| 示例 | `WorkflowGallery/ip`、`WorkflowGallery/code`，`gallery.json` 新增「系统」类 |

**条目字段**（`ask-launcher-workflows.md` §4.2）：

- ↩：`action` + `arg`。不写 `action` 时，http(s) 链接、`file:` 和以 `/`、`~` 开头的路径打开，其他复制。`open` 只打开 http(s) 和文件，别的 scheme（`javascript:`、`mailto:` 等）不打开；条目可以加 `"app": "Visual Studio Code"`，用这个应用打开文件或文件夹（找不到这个应用时按 Finder 的方式打开）。`paste` 写回（有选中文字时是「替换选中」），`reveal` 在 Finder 中显示，`run` 把 `arg` 填进输入框再运行一次，`askAI` 把 `arg` 交给 AI。
- ⌥↩：`mods.alt` 的 `action` / `arg` / `valid`，默认写回 `arg`。`mods.alt.subtitle` 能读，但没有显示（启动器没有「按住 ⌥ 换副标题」）。`mods.cmd` 等其他修饰键忽略：⌘↩ 永远是问 AI，问的是选中的那一行。
- ⌘C：`mods.copy.arg` 或 Alfred 的 `text.copy`，再没有就复制 `arg`、标题；不关闭启动器。
- ⇥：选中的行有 `autocomplete` 时，填进输入框并立即重新运行（逐级深入）；没有时 ⇥ 照旧切换选项。`valid: false` 的行 ↩ / ⌥↩ 不做事，但有 `autocomplete` 时 ↩ 也是补全（和 Alfred 一样）。
- 图标：`sf:符号名`；图片文件（相对工作流文件夹、`~` 或绝对路径）；`{"type": "fileicon", "path": …}` 显示这个文件的图标；`{"type": "filetype", "path": "public.folder"}` 显示类型图标。没有图标的行用工作流的图标。
- 容错：没有标题的条目跳过；标题、`arg`、`uid` 可以是数字；`arg` 是数组时按行合并；`valid` 可以写成 `"no"`、`0`；不认识的 `action` 按默认处理；最多 200 条。空列表显示一行「没有结果」。
- `display: items` 但输出不是列表：按文本显示，并提示「输出不是条目列表」；`{"text": "…"}` 按文本卡片显示。`auto` 不提示。

**重跑和参数**：

- `rerun`：最小 0.5 秒。只在结果还显示着时安静地重跑：不显示骨架，结果到了直接替换，按 `uid` 保持选中的行（行没了就留在原来的位置）。输入变化、按 ⌘R / ⇥、退出关键字模式、关闭启动器都会停止。重跑出来的结果不再执行「运行成功后」的动作（只在第一次结果时执行一次）。运行失败时停止重跑，显示错误卡片。
- `variables`：在这次关键字模式里，作为之后每次运行的 `options` 传回（stdin 的 `options`、`TYPEFLUX_OPTION_*`），退出关键字模式后清空。
- 列表在脚本打印时不逐行显示（半个 JSON 没法显示），显示骨架；`auto` 下以 `{` 开头的输出同样。

**Markdown**：复用随便问的渲染（`AskTranscriptText` / `AskMarkdownText`）：标题、列表、表格、代码块、链接（只有 http(s) 和 mailto 可点）。卡片高度按真实排版算出，最高 280pt，超出滚动。↩ / ⌥↩ 复制、写回的是 Markdown 原文。

**示例**：

- `ip`（zsh，「系统」类）：列出本机各网络端口的 IPv4 / IPv6 地址和本机主机名；`ip 192.168` 只列出匹配的。↩ 复制，⌥↩ 写回。不查公网 IP，不联网。
- `code`（zsh，「系统」类）：列出 `~/Projects ~/Code ~/Developer ~/src ~/GitHub` 下的文件夹（最近修改的在前，最多 50 个），`code web` 按名称过滤；↩ 用编辑器打开（依次找 Visual Studio Code、Cursor、Zed、Sublime Text、Nova、BBEdit），⌥↩ 在 Finder 中显示，⌘C 复制路径，行图标是文件夹图标。查找目录和编辑器是关键字的预设参数 `roots`、`editor`。
- 两个示例的详情页里，「启动器里的样子」按列表显示；「会做什么」写「显示列表供选择」。

### 逐屏对照

截图由 `WorkflowItemsVisualTests` 用真实视图渲染（`TYPEFLUX_ASK_SNAPSHOTS=<目录> swift test --filter WorkflowItemsVisualTests`）。

| 设计稿 | 实现 | 对照结果 |
|---|---|---|
| ⑦ `ed-items.png` | `implemented-ed-items(-light).png` | 一致：「条目列表」可选，Markdown 卡片可选，图片标「即将支持」；步骤条「列表 · 2 个动作」；右侧「启动器里的样子」是可点选的列表（选中行蓝底，写出「↩ 复制」），下面的按键提示换成选中行的 ↩ / ⌥↩ / ⌘C；「这次运行成功后会执行」用 `{json.items.0.…}` 取值。 |
| — | `implemented-launcher-items(-light).png` | 启动器里的列表：图标、标题、副标题，选中行蓝底并写出 ↩ 的动作；底栏「↩ 复制 · ⌥↩ 插入 · ⌘↩ 问 AI」。 |
| — | `implemented-launcher-markdown.png` | Markdown 卡片：标题、表格（右对齐的列）、行内代码、粗体，下面是复制 / 插入 / 对照 / 重新运行。 |
| — | `implemented-ed-markdown(-light).png` | 编辑器选「Markdown 卡片」时的预览。 |
| — | `implemented-g-detail-ip.png`、`implemented-g-detail-code.png`、`implemented-g-list-o3.png` | 示例库：「系统」类两个新示例，详情页的启动器预览按列表显示。 |

对照时发现并修了：选中行写「↩ 用 Visual Studio Code 打开」这类长动作名时，行被撑宽、溢出示例库对话框（改为标题优先，动作名截断）；预览下面的按键提示放不下时整行溢出（改为放不下就少显示几个）。

和设计稿的差异：设计稿 ⑦ 里列表的按键提示只有「↩ 复制」，实现里按选中行列出 ↩ / ⌥↩ / ⌘C / ⌘↩。
