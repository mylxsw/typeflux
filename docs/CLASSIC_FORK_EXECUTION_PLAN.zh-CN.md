# Typeflux Classic 执行方案（基于 0.4.0 分支独立维护）

本方案取代 [VOICE_CORE_PACKAGE_DESIGN.zh-CN.md](VOICE_CORE_PACKAGE_DESIGN.zh-CN.md)（核心包拆分方案已搁置）。

- **Typeflux Classic**：纯语音输入法，从 v0.4.0 独立出来维护。语音功能以后只修 bug；账户、登录、计费、账单这一块与 Typeflux 保持同步。
- **Typeflux**：完整的 macOS 效率工具，即主仓库 1.x。

方案按工作包和上线关卡组织，不设排期。任务由 Claude 规划、分派给代理执行并统一审查；需要人工配合的事项列在第 10 节。

---

## 1. 已确认的决定

| 项 | 决定 |
|---|---|
| 身份 | 两个产品共用 Bundle ID `ai.gulu.app.typeflux` 和文件名 `Typeflux.app`，同一台电脑上只装其中一个。Classic 的显示名是"Typeflux Classic"。 |
| 数据 | 共用同一份数据，两边互通。 |
| 账户 | 账户、会员、支付完全共用。 |
| 个人中心、计费、账单 | 与 Typeflux 保持同步：Classic 直接使用 1.0 的账户模块，以后随 1.0 一起更新（见 4.5）。 |
| 代码 | 新建 `mylxsw/typeflux-classic` 仓库，从 v0.4.0 开始，保留 Git 历史。 |
| 更新 | 服务端按产品分流：0.x 和 Classic 只推 Classic，1.x 和 Typeflux 只推 Typeflux。 |
| 产品标识 | 请求头、埋点、更新请求、日志都带上产品标识。服务端同时用产品标识和版本号区分产品。 |
| 版本号 | Classic 沿用 0.x（第一版 0.5.0）。 |
| 统计 | 只加一张按产品区分的图表，其余统计按一个产品看待。 |
| 1.0.1 弹窗 | 一次性弹窗，对象是首次启动 1.0.1 时 `onboarding.completed` 已经为 true 的用户。 |
| 暂不处理 | 防止同时运行两个实例的保护。 |

## 2. 事实依据（已对照代码核实）

### 2.1 v0.4.0 实际对应哪份代码

v0.4.0 位于 `pre-release` 分支，由一个 squash 提交 `bf156b66 prerelease (#163)` 构成。它的 `Sources/` 与 main 上的 `3a1e4468`（2026-09-17）**完全一致**。所以凡是 2026-09-17 之前合进 main 的修复，0.4 都已经包含。`git cherry` 在 squash 上判断不出哪些修复已包含，回移清单（第 7 节）以这个时间点为准。

### 2.2 1.0 写下的数据，0.4 能否读懂

| 数据 | 结论 |
|---|---|
| `history.sqlite` | 建表语句、补字段的迁移、`HistoryRecord.Mode` 和 `StepStatus` 的取值都没变。 |
| UserDefaults | 0.4 代码读取 74 个键。1.0 代码里不再出现的只有 `agent.enabled`、`agent.frameworkEnabled`、`agent.stepLoggingEnabled`、`voiceInput.quickInput.enabled`，1.0 不碰它们，没有冲突。1.0 会删除的 5 个键（`analytics.pendingEvents`、`hotkey.custom.json`、`stt.alicloud.model`、`stt.soniox.model`、`typefluxCloud.loginReminder.lastShownAt`），只在用户主动清空或关闭对应功能时删除，0.4 读不到时回退到默认值，影响无害。 |
| 人设、词汇、热键 | 键名和 JSON 结构相同。 |
| Keychain | `KeychainTokenStore` 自 0.4 起没有改动。 |
| 数据目录 | 1.0 把 `~/Library/Application Support/Typeflux` 移到 `~/.typeflux/data`，并在旧路径留下符号链接。0.4 通过这个链接照常读写。 |
| 云同步 | 只改了约 2 行。 |
| **唯一的分歧** | 1.0 把"润色用哪个模型"存在 `llm.profile.reference` 和 `models.registry.v2`，0.4 不读这两个键。见 W2-C3。 |

### 2.3 服务端已经兼容 0.4

- `typeflux-api/docs/legacy-v040.md` 记录了 0.4 兼容规则。服务端靠请求**不带 `X-Typeflux-Credit-Version`** 来识别旧协议客户端：额度按整数返回，原有的原生接口照常可用。
- 服务端从 User-Agent `Typeflux/<版本>` 里解析版本号。Classic 的 `CFBundleName` 保持 `Typeflux`，所以解析不受影响。
- 新旧额度协议的区别在服务端很小（`middleware/credit_protocol.go`、`response/credits.go`）：不带 `X-Typeflux-Credit-Version` 的请求只能调用 6 个老的扣费或账单 POST 接口（对话、ASR 令牌、订阅同步、结账、账单门户、账单页），用量接口按整数返回额度。带 `X-Typeflux-Credit-Version: 2` 的请求可以调用全部账单接口（加量包、预付费会员等），额度按小数返回。两种协议的价格、预扣和结算完全相同。
- 刷新令牌采用轮换机制。每次登录开一条独立的登录链（family）；已经换过的刷新令牌再被使用，服务端会吊销这条链，即这台电脑的这一次登录。服务端默认访问令牌有效期为 15 分钟（`JWT_EXPIRES_IN`）。

## 3. 两个产品的关系

```
                      typeflux-api（一套账户、会员、额度、数据接口）
                   ┌───────────────────┴────────────────────┐
        新额度协议（Credit-Version 2），同一套账户模块代码
   Typeflux Classic 0.5.x（typeflux-classic 仓库）     Typeflux 1.x（typeflux 仓库）
   x-client-product: classic                          x-client-product: typeflux
   不发送 1.0 的功能路由、Ask、词典请求头             全部协议

   旧协议（不带 Credit-Version）只剩还没更新的 0.4.0 在用
                   └──────── 同一份本地数据 ~/.typeflux/data ────────┘
                         同一个 Bundle ID、Keychain、UserDefaults
```

## 4. 关键约定

### 4.1 服务端怎样判断产品

1. 请求头 `X-Client-Product`，或更新请求的 `product` 参数，取值为 `classic` 或 `typeflux` 时直接采用。
2. 没有带，或取值不认识时，按版本号推断：低于 `1.0.0` 判为 `classic`，其余判为 `typeflux`。已经装在用户电脑上的 0.4.0 和 1.0.0 都不带这个标识，全靠这一条推断。
3. 判断结果写进 `requestmeta.ClientInfo.Product`，请求日志、埋点、统计都从这里取值。

### 4.2 更新分流

| 客户端 | 推送内容 |
|---|---|
| 0.4.0（无产品标识） | 最新的已发布 Classic。如果还没有任何已发布的 Classic，返回 `should_update=false`，让这些用户暂时停在原版本。 |
| Classic 0.5.x | 同上。 |
| 1.0.0（无产品标识） | 最新的 Typeflux。 |
| Typeflux 1.0.1+ | 最新的 Typeflux。 |

自动更新永远不会跨产品。跨产品切换只有两种途径：用户自己下载安装，或者使用 1.0.1 里的"切换到 Classic"按钮（W3-M3）。

### 4.3 Classic 使用哪套协议

- **额度和账单**：Classic 与 1.0 一样发送 `X-Typeflux-Credit-Version: 2`，使用新额度协议，额度按小数显示，可以调用全部账单接口。这是同步账户模块的前提。
- **功能请求**：Classic 不发送 1.0 的功能路由请求头（`X-Typeflux-Feature`、`X-Typeflux-Model-Catalog`）、词典请求头、Ask 和 Agent 的 capability 请求头。服务端对不带这些请求头的请求按默认路由处理。
- **旧协议**：只服务还没更新的 0.4.0。Classic 0.5.0 发布后，这部分流量会逐步减少，最终可以下线（W1-S10）。
- 回移语音链路的代码时，不能顺带引入 1.0 的功能路由或 Ask 协议。

### 4.4 共享数据契约

1.x 必须遵守以下规则，由 W3-M4 的契约测试在 CI 中强制执行：

1. 0.4 读取的 74 个 UserDefaults 键不删除、不改名、不改值的类型和格式。只有用户主动清空某项设置时可以删除对应的键。
2. `history_records` 表只能新增可为空的字段。已有字段不改类型、不删除，`mode` 和 `*_status` 不新增取值（0.4 遇到解析不了的行会直接跳过）。
3. `PersonaProfile`、`HotkeyBinding`、词汇表的 JSON 只能新增可选字段。
4. 旧数据路径 `~/Library/Application Support/Typeflux` 必须一直可以访问：要么是真实目录，要么是指向新位置的符号链接。
5. Keychain 中账户和令牌的存储项不改名。

### 4.5 账户模块同步机制

个人中心、计费、账单要和 1.0 保持一致，所以这一块不逐个回移提交，而是**直接使用 1.0 的代码，并随 1.0 一起更新**。

**同步范围**（清单文件 `account-module.txt`，放在 Classic 仓库）：

- `Auth/` 整个目录，共 42 个文件：登录（网页登录与原生登录代码）、会话、令牌、个人资料、订阅、预付费会员、额度、加量包、用量、账单流程、账户页的所有视图。
- `Networking/` 下与计费相关的错误：`TypefluxCloudBillingError`、`CloudCreditsExhaustedError`、`TypefluxCloudServerErrorMessage`。
- `App/BillingReturnLink`（从网页账单页返回应用）、`App/AppLoginURLRouter`（登录和账单回调路由）。
- `UI/StudioSidebarAccountCard`、`UI/SidebarAccountFooter`、`UI/SidebarAccountIdentity`（设置侧栏的账户卡片）。
- `STT/TypefluxOfficialASRGrantSequence`：`AuthState` 用到了其中的会话凭证类型。
- 对应的测试文件：主仓库中账户、账单、登录、额度相关的测试，约 40 个，以清单为准。

**规则**：

1. 清单里的文件在 Classic 中**与上游逐字节一致**，不做本地修改。
2. 适配 Classic 的代码全部放在 `Sources/Typeflux/ClassicShims/`。1.0 的账户模块用到的多进程接口很少：`FeatureProcess.enabled`、`.role`、`.owns`、`.send`，`FeatureAuth.refresh`，`FeatureRPC.Failure.unavailable`。在 Classic 中，`FeatureProcess.enabled` 恒为 `false`，所有分支都走单进程路径。`RecentInputMemoryStore` 用空实现代替；`OnboardingCloudModel` 的 `activeSession` 和 `activeLogin` 接到 Classic 自己的引导流程上。
3. 同步脚本 `scripts/sync_account_module.sh <上游提交>`：按清单从上游复制文件，并在 `UPSTREAM_ACCOUNT_SYNC` 中记录上游提交和每个文件的哈希。
4. Classic 的 CI 校验清单内的文件与记录的哈希一致，防止有人在本地修改模块文件。
5. 主仓库的 CI 用边界检查脚本守住模块边界（W3-M7）：账户模块只能引用 0.4 已有的类型、模块自身的类型，以及 shim 清单中的类型。新增的依赖会让检查失败，提醒同步扩充 shim 或清单。

---

## 5. 工作包

每个工作包对应一个仓库，由一个代理在独立的 worktree 中完成，Claude 审查后合并。

### W1 服务端（typeflux-api）

| 编号 | 任务 | 验收标准 |
|---|---|---|
| S1 | `app_releases` 表新增 `product` 字段（`typeflux` 或 `classic`，默认 `typeflux`，非空），版本号唯一约束改为按产品区分。 | 迁移可以重复执行；存量发布记录全部归为 `typeflux`。 |
| S2 | `AppReleaseService` 按产品分别缓存最新发布：`Latest(product)` 和 `Check(product, version, arch)`。 | 两个产品的最新版本互不干扰。 |
| S3 | 新增 `ResolveClientProduct(explicit, version)`，实现 4.1 的规则，`client_metadata` 中间件读取 `X-Client-Product` 并写入 `ClientInfo.Product`。 | 覆盖四种情况：有效标识、无效标识、无标识且版本 0.x、无标识且版本 1.x。 |
| S4 | `/api/v1/app/update` 接受 `product` 参数，按 4.2 返回；Classic 暂无已发布版本时返回 `should_update=false`。 | 0.4.0 的请求在任何情况下都拿不到 1.x 的下载地址。 |
| S5 | `/api/v1/app/releases/latest` 和 `/d/:platform/:arch/:channel` 支持 `?product=classic`，不带参数时行为与现在一致。 | 官网现有下载链接不受影响。 |
| S6 | 后台发布管理接口支持 `product` 字段；Classic 的发布模板 `source_url` 指向 `github.com/mylxsw/typeflux-classic/releases/tag/v{version}`。 | 能分别创建、发布和停用两个产品的版本。 |
| S7 | 埋点：`product` 加入属性白名单并存为可筛选的字段；不带标识的事件按 4.1 推断。 | 看板能按产品分组。 |
| S8 | 请求日志和错误日志带上 product。 | 日志检索可以按产品过滤。 |
| S9 | 新增 Classic 协议契约测试：带 `x-client-product: classic` 和 `X-Typeflux-Credit-Version: 2`、不带功能路由请求头的请求，能正常调用对话、ASR 令牌、订阅、额度、加量包、预付费会员、用量明细、收据、反馈上传接口，对话走默认路由。`docs/legacy-v040.md` 注明：旧协议只服务没更新的 0.4.0。 | 测试纳入 CI。 |
| S10 | 原生登录接口（`/auth/login`、`/auth/oauth/*`、`/auth/register` 等）和旧额度协议继续保留，因为还没更新的 0.4.0 仍在使用。看板上按产品和版本统计原生登录调用量，以及不带 Credit-Version 的请求量；以后要下线时，以这两个数据为依据。 | 有统计数据，不擅自下线。 |

### W2 Classic 仓库（typeflux-classic）

| 编号 | 任务 | 验收标准 |
|---|---|---|
| C0 | 用 v0.4.0 的历史建库，默认分支 `main`；添加主仓库为 `upstream` 远程，方便 cherry-pick；复制 0.4 的发布工作流，产物命名为 `Typeflux-Classic-<版本>-<架构>.{zip,dmg}`，包内仍是 `Typeflux.app`。 | CI 可以构建出签名并公证的产物（需要第 10 节的证书和密钥）。 |
| C1 | 身份：`CFBundleDisplayName` 改为 `Typeflux Classic`，`CFBundleName` 保持 `Typeflux`，版本号 0.5.0，`CFBundleVersion` 大于 0.4.0。菜单栏、关于窗口、设置页标题显示"Typeflux Classic"，五种语言都要改。 | 在 Finder、启动台、程序坞、权限弹窗、登录项里显示的名称已核实（W6）。 |
| C2 | 产品标识：在 `TypefluxCloudRequestHeaders.applyClientInfo` 中加 `x-client-product: classic`，覆盖所有云端请求，包括 ASR 的 WebSocket 握手；埋点公共属性加 `product: classic`；更新请求加 `product=classic`；诊断导出加上产品信息。 | 抓包可以看到每个云端请求都带有这个标识。 |
| C3 | 模型选择桥接（下文详述）。 | 契约夹具测试通过（C11）。 |
| C4 | 回移反馈上传的安全修复（来自 3acb3636、c25f1d1b 中反馈上传的部分）：上传地址只能是本应用配置过的 API 来源，不能取自响应；令牌不发往其他来源。 | 有单元测试；构造一个指向外部来源的上传票据，客户端拒绝上传。 |
| C5 | **账户、登录、计费、账单模块整体同步**（按 4.5 的机制）。完成后 Classic 具备 1.0 的全部账户能力：网页登录（设置页和引导流程都改为网页登录，原生登录入口与 1.0 一样不再显示）、登录刷新单飞和会话隔离（GUL-289/296）、账单请求的会话隔离（GUL-301/306）、个人中心页面、套餐卡片、预付费会员到期时间和网页续费、小数额度及额度图表、加量包、用量明细和收据、从网页账单页返回应用。同时把 `TypefluxCloudRequestHeaders` 中与额度协议相关的部分改为发送 `X-Typeflux-Credit-Version: 2`（4.3）。Classic 侧的接入工作：在 0.4 的设置窗口中嵌入 1.0 的账户页和侧栏账户卡片；引导流程中的账户步骤改为网页登录；在 `AppDelegate` 中接入 `AppLoginURLRouter`；语音流程的额度不足提示改用 `CloudCreditsExhaustedError`。 | 清单内的文件与上游哈希一致；同步来的测试全部通过；W6 第 7、8、10–13 项实测通过。 |
| C6 | 回移 ASR 故障切换的修复（来自 3acb3636 中 ASR 的部分）：每次切换服务器都申请新的一次性授权；音频一旦发出，失败即为最终结果，不换网关重放。`TypefluxOfficialASRGrantSequence` 已经随 C5 进入 Classic，这里把语音识别器接上它。 | 故障切换测试通过。 |
| C7 | 回移崩溃修复：7c4c0738（共享音频缓冲）和 c84c42a5（实时音频队列上限、PCM 切片重置崩溃）。两者都依赖新文件 `AudioPCMBufferSnapshot.swift`，一起移植。 | 原有测试和移植来的测试都通过。 |
| C8 | 候选回移：第 7 节中标记为"先验证"的项目。先在 0.4 代码上复现，确认存在问题再移植。 | 每项记录复现结果和处理结论。 |
| C9 | 在设置页和关于窗口加"了解完整版 Typeflux"入口，打开官网对比页。不提供自动升级。 | — |
| C10 | 更新器加一层保护：产品是 Classic 时，忽略任何 ≥1.0 的版本，即使服务端返回了这样的版本。 | 单元测试覆盖。 |
| C11 | 契约夹具测试：读取主仓库生成的夹具（W3-M4），验证 Classic 能正确读取 1.0 的设置、历史和人设，模型桥接的映射正确，Classic 写入时不会删除 1.0 的键。 | 测试纳入 CI；夹具更新后重新运行。 |

**C3 模型选择桥接**

读取方向（Classic 启动时，以及设置窗口打开时）：

- `llm.profile.reference` 为空：维持 0.4 的原有行为。
- `cloud:default`，或解析到 `typefluxCloud`：设置 `llm.provider=openAICompatible`、`llm.remote.provider=typefluxCloud`。
- 在 `models.registry.v2` 中解析到内置服务商（`provider.remote` 非空）：设置 `llm.provider=openAICompatible`、`llm.remote.provider=<remote>`，以及 `llm.remote.<remote>.model=<model.id>`。
- 解析到 `ollama`：设置 `llm.provider=ollama` 和 `ollamaModel`。
- 解析到自定义端点（`endpoint:`）或解析失败：不改动 0.4 的设置，在设置页显示一次提示"完整版中选择的自定义模型在 Classic 中不可用"。
- 读取注册表时只解析用得到的字段，遇到不认识的字段直接忽略，绝不回写 `models.registry.v2`。

写入方向（用户在 Classic 中修改润色模型时）：

- 先写 0.4 的原有键。
- 再在注册表里查找同一服务商下 `id` 相同的模型：找到就把 `llm.profile.reference` 设为它的 reference；找不到就删除 `llm.profile.reference`。1.0 在这个键为空时使用旧键（`SettingsStore.effectiveLLMProvider`、`textLLMConfiguration`），因此用户切回 1.0 时看到的是 Classic 中的选择。

### W3 主仓库（typeflux，1.0.1）

| 编号 | 任务 | 验收标准 |
|---|---|---|
| M1 | 产品标识：`applyClientInfo` 中加 `x-client-product: typeflux`；埋点公共属性加 `product: typeflux`；更新请求加 `product=typeflux`。 | 抓包核实。 |
| M2 | Classic 介绍弹窗：首次启动 1.0.1 时，先记录 `onboarding.completed` 在本次启动前是否已为 true，满足条件且 `classic.intro.shownVersion` 不存在才显示。如果本次需要走引导流程，弹窗等引导结束后再出现。按钮：「继续使用 Typeflux」「切换到 Typeflux Classic」「了解区别」。显示后写入 `classic.intro.shownVersion`。 | 全新安装不弹；从 1.0.0 升级弹一次；重启后不再出现。 |
| M3 | 一键切换到 Classic：弹窗和"设置 → 关于"中都提供入口。流程：调用 `/api/v1/app/releases/latest?product=classic` 拿到当前架构的 `app_only_zip`，复用 `AutoUpdater` 的下载、校验、安装、重启流程。新增校验：下载的应用 Bundle ID 必须与当前一致，Team ID 必须与当前签名一致，否则拒绝安装。确认框说明数据会保留，也说明 Classic 中没有哪些功能。切换前先停止各个功能子进程。服务端没有已发布的 Classic 时，隐藏这个入口。 | W6 实测切换后数据、登录状态、系统权限都保留。 |
| M4 | 共享数据契约测试 `ClassicCompatibilityContractTests`：①用 0.4 的 74 个键作为夹具，执行 1.0 的 `SettingsStore` 初始化和所有迁移，断言这些键依然存在、类型不变；②用 1.0 的存储层建库，断言 0.4 的字段集合、类型和非空约束不变，`Mode` 和 `StepStatus` 的取值集合与冻结清单一致；③人设、热键、词汇的 JSON 能按 0.4 的结构解码；④数据目录迁移后旧路径依然可以访问。同时把 1.0 生成的设置 plist、`history.sqlite` 和模型注册表导出到 `Tests/Fixtures/ClassicContract/`，供 C11 使用。 | 测试纳入 CI；违反契约时测试失败。 |
| M5 | 文档：在 AGENTS.md 和 CLAUDE.md 加一段"Classic 数据契约"，指向本文 4.4；在核心包设计稿开头标注已搁置。 | — |
| M6 | 更新器保护：产品是 Typeflux 时，忽略服务端返回的 0.x 版本。只有 M3 主动发起的切换可以安装 Classic。 | 单元测试覆盖。 |
| M7 | 理清账户模块边界，让 Classic 同步时不需要额外适配：把 `AskAccountProgressBar`、`AskAccountTone` 移到 `Auth/` 或 `UI/`；`WebLoginView` 不再依赖 `AskWindowBackdrop`；`AuthState` 退出登录时改为发通知，由 `RecentInputMemoryStore` 自己订阅并清空，不再直接调用；`OnboardingCloudModel` 通过一个小协议接入。新增 `scripts/check_account_module_boundary.py` 并纳入 CI（4.5 第 5 条）。 | 重构不改变行为，相关测试通过；边界检查在 CI 中运行。 |

### W4 后台看板（typeflux-dashboard）

| 编号 | 任务 | 验收标准 |
|---|---|---|
| D1 | 发布管理页增加产品选择和按产品筛选；两个产品分别显示"当前版本"。 | 不会把 Classic 版本误发布成 Typeflux。 |
| D2 | 增长分析页加一张图：按产品区分的活跃客户端趋势。 | 图中包含不带产品标识的老客户端（按版本推断）。 |

### W5 官网与文档（typeflux-homepage、typeflux-docs）

| 编号 | 任务 |
|---|---|
| H1 | 下载页增加 Classic 区块，链接为 `/d/...?product=classic`；Classic 的更新日志单独存放。 |
| H2 | 文档：Classic 与 Typeflux 的区别；双向切换指南，说明哪些数据保留，以及 Classic 中看不到 1.0 的 Ask 等功能的数据。 |

### W6 Mac 端到端验证

使用已配置的 Mac 工作机（macrun）或实体机，在测试环境的服务端上完成：

1. 装 0.4.0，等待自动更新到 Classic 0.5.0：历史、设置、登录状态、辅助功能和麦克风权限都保留。
2. 从 1.0.0 升级到 1.0.1：弹窗只出现一次；全新安装的 1.0.1 不弹。
3. 在 1.0.1 中一键切换到 Classic：模型选择映射正确，历史可见，登录状态保留，权限保留。
4. 在 Classic 中修改模型和人设，再手动装回 1.0.1：修改已生效，不会重新走引导。
5. Classic 不会收到 1.x 的更新推送，1.0.1 不会收到 0.x 的更新推送。
6. "Typeflux Classic"在 Finder、启动台、程序坞、菜单栏、权限弹窗、活动监视器、登录项中的实际显示。
7. Classic 的个人中心与 1.0 一致：额度按小数显示，额度图表、用量明细、收据正常；购买会员、购买加量包、从网页账单页返回应用；云端语音识别、润色、额度不足提示。
8. 访问令牌有效期设为 15 分钟时，快速连续打开设置窗口和账户页，Classic 不会掉登录。
9. 反馈上传的来源校验生效。
10. Classic 的网页登录：从设置页和引导流程各登录一次；浏览器回调能正确回到 Classic；取消登录、登录超时、登录过程中退出应用，都能正确处理。
11. 预付费会员账号在 Classic 中显示到期时间和网页续费入口，不显示"管理账单"。
12. 同一账号在 Classic 和 1.0 之间切换，个人中心显示的数据一致。
13. 在 Classic 中退出登录、换账号：旧账号的订阅、额度、账单结果不会出现在新账号里。

---

## 6. 上线关卡（按依赖顺序）

| 关卡 | 内容 | 前提 |
|---|---|---|
| G0 | 核实两件事：生产环境的 `JWT_EXPIRES_IN`；生产上当前发布的版本是否已经在向 0.4 用户推送 1.x。 | — |
| G1 | 部署 W1（S1–S10）。0.x 用户暂停接收更新。**如果 G0 确认 0.4 用户正被推送 1.x，G1 优先于其他所有工作。** | W1 测试通过 |
| G2 | Classic 0.5.0 候选版本通过 W6 的 1、3–13 项。 | W2 完成、G1 |
| G3 | 1.0.1 候选版本通过 W6 的 2–5 项。 | W3 完成、G1 |
| G4 | 在后台发布 Classic 0.5.0（product=classic），0.4 用户开始自动更新。 | G2 |
| G5 | 发布 1.0.1。 | G3、G4（一键切换依赖已发布的 Classic） |
| G6 | 官网、文档、看板图表上线。 | G4 |

**回滚**

- Classic 出问题：在后台停用这个 Classic 版本，0.x 用户回到暂停更新的状态。1.0.1 查不到已发布的 Classic，自动隐藏切换入口。
- 1.0.1 出问题：停用 1.0.1，按现有方式处理。

## 7. 回移清单

范围：2026-09-17（`3a1e4468`）之后合入 main 的改动。为避免遗漏，从四个方向排查，而不是只看标题带 fix 的提交：

1. **接口对照**：0.4 调用的所有服务端接口在 1.0 里还在调用，在服务端（`typeflux-api`、`realtime-asr`）也都还在。1.0 新增的账户类接口只有网页登录的两个（`/auth/app/*`），以及额度明细、收据两个查询接口。
2. **服务端策略文档**：`legacy-v040.md`、`web-app-auth.md`（原生登录接口继续保留）、`prepaid-memberships.md`。
3. **产品策略变更**：账户、登录、会员、额度、反馈相关目录下的所有提交，不论标题是什么。
4. **语音链路的修复**：Workflow、STT、Audio、Hotkey、Overlay、TextInjection、History 目录。

### 7.1 产品策略对齐

| 分类 | 提交 | 内容 | Classic 的处理 |
|---|---|---|---|
| 必须 | d0716b7c、41869f3f、4feec397、f999d345 | macOS 一律改为网页登录 | C5 |
| 必须 | 9b3b76fd | 预付费会员的显示和网页续费 | C5 |
| 必须 | 25a90c6e、444a8bd7、6d24d170、a8c27942、0a4b4c98 | 个人中心页面、套餐卡片、额度与用量展示 | C5 |
| 必须 | 1d3cd6b8、54b268eb | 小数额度及其显示 | C5；Classic 改用新额度协议 |
| 不跟进 | 1259175d | 本地数据统一放到 `~/.typeflux` | Classic 通过旧路径的符号链接访问；全新安装时使用旧路径，以后装 1.0 时由 1.0 迁移 |
| 不跟进 | 81343df0、b58a2ccd | 云端文本请求按功能路由、词典语言信息 | 属于 1.0 的功能路由协议；Classic 不发送这些请求头，服务端按默认路由处理 |

### 7.2 安全与正确性

| 分类 | 提交 | 内容 | 依据 |
|---|---|---|---|
| 必须 | 3acb3636 / c25f1d1b / fa1ed7cf（部分） | 反馈上传来源校验（C4）；登录刷新单飞和会话隔离（C5） | 安全问题；服务端吊销规则会导致掉登录 |
| 必须 | 4fa6cd85、ae7d0f5b、09b79f06 | 账单请求的会话隔离 | 换账号后旧结果会出现在新会话里；C5 |
| 必须 | 7c4c0738 | 共享音频缓冲导致的语音输入崩溃 | 崩溃；改动集中在 0.4 已有的文件 |
| 必须 | c84c42a5 | 实时音频队列上限、PCM 切片重置崩溃 | 崩溃 |
| 必须 | 3acb3636（ASR 部分） | 故障切换时申请新的一次性授权 | 现网关按一次性授权处理；所需类型已随 C5 进入；C6 |
| 先验证 | 611d4dc3 | 胶囊隐藏后动画计时器仍在运行 | 耗电；涉及 `OverlayController` |
| 先验证 | 343fc9eb（粘贴部分） | 粘贴验证、大图听写 | 涉及 `AXTextInjector` |
| 先验证 | 706860d8（辅助快捷键部分） | 辅助快捷键手势 | 辅助快捷键已在 0.4 中 |
| 先验证 | 773588b7（STT 回退部分） | 恢复云端语音识别的回退 | 先确认是 0.4 已有的问题，还是 1.0 才引入 |
| 不回移 | 2607188c、ab3b72d3、d223888e、eb0f185b、62587435 | 多进程架构、启动器、通知面板 | 只涉及 1.0 新增的模块 |
| 不回移 | 6504a783、5a2a46ec、06d0ebba、36a7415d | 翻译、Ask 记忆、新反馈界面 | 不在 Classic 的范围内 |

## 8. 风险与对策

| 风险 | 对策 |
|---|---|
| 从 1.0 降级的用户觉得 Classic 的语音体验退步 | 回移崩溃类修复；切换确认框如实说明差异 |
| 主仓库改动在不知情时破坏 Classic | M4 契约测试纳入 CI，AGENTS.md 写明契约 |
| 服务端改动破坏旧协议 | S9 契约测试；legacy 文档同步更新 |
| 回移语音代码时把 1.0 的功能路由或 Ask 协议带进 Classic | 4.3 约束；每个回移 PR 审查时检查请求头和接口变化 |
| 账户模块依赖 1.0 改过的界面组件（`StudioTheme`、`StudioCard` 等在 0.4 中也有，但接口可能已经变了） | 编译时暴露；需要的组件文件一并列入 4.5 的同步清单 |
| 账户模块以后在 1.0 里越长越大，同步成本上升 | M7 的边界检查让新增依赖在主仓库 CI 中就暴露；Ask 专用的账户界面不进清单 |
| Classic 改用新额度协议后行为与 0.4 不同 | 服务端两种协议的价格和结算相同，差别只在额度显示和可用接口；S9 契约测试覆盖 |
| 显示名在部分系统界面中没有生效 | W6 第 6 项实测；如果不生效，接受只在应用内区分 |
| 一键切换时下载的包被篡改 | M3 校验签名、Bundle ID 和 Team ID |
| 0.4 用户在 G1 之前已经被推送 1.x | G0 核实；必要时 G1 最先部署 |

## 9. 长期维护规则

1. 语音功能只接受四类改动：崩溃、数据丢失、安全问题、服务端兼容。每个回移 PR 注明对应的 main 提交。
2. 账户、登录、计费、账单模块随 1.0 同步：1.0 每次发版时，只要账户模块的清单文件有变化，Classic 就运行同步脚本跟进，并在下一个版本发出。
3. 主仓库中，账户模块以外但与账户、会员、支付、额度相关的改动（比如语音流程里的额度不足处理），PR 中必须回答一个问题："Classic 是否需要跟进？"需要的话，同时开一个 Classic 任务。这一条写进主仓库的 PR 模板。
4. 两个仓库的 CI 都运行契约测试；主仓库的夹具更新后，Classic 必须重新运行一次。
5. 服务端调整接口时，必须同时满足旧协议文档（针对 0.4.0）和 S9 的 Classic 契约测试。
6. Classic 版本号保持 0.x。
7. 下线 Classic 时：停止发布新版本，最终版保持可用；如有需要，再加一个引导切换到 Typeflux 的提示。

## 10. 需要你配合的事项

1. 创建 GitHub 仓库 `mylxsw/typeflux-classic`（或者授权我创建），并配置签名证书、公证账号等 CI 密钥。
2. 提供生产环境的 `JWT_EXPIRES_IN`，以及当前已发布的版本号（G0）。
3. 可用的测试环境服务端，以及 Mac 验证环境的访问方式（W6）。
4. 服务端部署和正式发布的操作，或者授权我执行。

## 11. 任务分派

- 每个工作包交给一个代理，在对应仓库的独立 worktree 中实现，按仓库规范运行聚焦测试并提交 PR。
- W1 先行；W2、W3 在 W1 的接口约定确定后并行；W4、W5 在 W1 合并后进行；W6 在 G2、G3 前执行。
- 每个 PR 由 Claude 审查，重点关注：是否违反 4.3、4.4、4.5，回移是否改变了请求协议，测试是否覆盖验收标准。
- W3-M7（账户模块边界）先于 W2-C5 完成，这样 Classic 第一次同步时就能直接使用干净的边界。
- 涉及对外的操作（建仓库、部署、发布）在执行前逐项向你确认。
