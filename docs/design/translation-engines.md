# 翻译服务：多服务并行与独立翻译模型

> 已实现（GUL-369 / P1–P3）。设置位置：「设置 → 启动器 → 翻译」。面板交互见 [translation-panel.md](translation-panel.md)。

## 服务模型与默认值

`AskTranslationSettings` v2 保存有序的 `services: [AskTranslationService]`。每条服务有稳定 ID、种类和启用状态；顺序决定结果序号和自动复制的第 n 项。

- **本机翻译**：Apple Translation，文字不出本机；可管理系统语言包。当前直接会话实现需要 macOS 26 和已安装的语言包，较早系统会显示该项不可用，已勾选的 AI / 服务商仍可在明确提交后运行。
- **AI 翻译**：可以添加多条，每条独立选择模型；空引用跟随文本处理模型。默认第一条保留，不能删除；第一条启用的 AI 负责单词卡。
- **服务商**：DeepL、Google、Microsoft、有道、百度、腾讯云、火山翻译；密钥只存钥匙串。

全新安装只启用本机翻译和第一条 AI。第三方服务由用户自己勾选；勾选未配置的服务直接打开该服务的密钥表单。设计稿勾选的额外服务和快捷键都是演示值，三个翻译快捷键正式默认不设置。

## 请求与隐私

`AskTranslationFanout` 在一次明确提交后并行调用勾选的服务，按设置顺序发布每项 `loading / streaming / done / failed`。单项失败不影响其它结果。AI 句子译文流式显示；本机、服务商和结构化单词卡整段返回。

启动器 `fy` 打字期间只请求本机翻译和读取本机单词本。面板按 ↩、划词翻译快捷键、截图翻译或启动器明确提交才调用远端。新输入取消旧任务，generation 检查丢弃不遵守取消的迟到结果。

查单词或短语时，第一条启用的 AI 写单词卡并置顶，其它服务默认收成一行。已有单词卡直接从单词本读取，跳过所有 AI；⌘R 只重新生成当前 AI 项。单词卡保留最多三条例句，默认显示两条，按「更多例句」展开剩余内容；UK / US 音标分别使用英式、美式朗读。

`engine=device|ai|deepl|google|microsoft|youdao|baidu|tencent|volcengine` 仍可在关键词中强制只调用一个服务，即使它在列表中未勾选。

## 结果操作和恢复

| 情况 | 操作 |
|---|---|
| 翻译完成 | 朗读、插入、复制译文、复制原文 + 译文；单词卡可复制整张 Markdown |
| 未配置 / 密钥无效 | 「去配置」直接打开该服务的密钥表单，保存后只重试该项 |
| 额度用完 | 「换一个服务」移除该项，本次会话后续输入也跳过；新会话恢复 |
| 网络 / 超时 | 「重试」只重新请求失败项，保留其它结果 |
| 不支持的语言 / 文本过长 | 显示原因，不自动改用 AI |

收起后显示一行预览，按服务 ID 记住收起 / 展开选择，面板和启动器共用。保存于本机 `ask.translation.collapsed.<service-id>`；未设置时查词的普通译文默认收起，单词卡展开。

## 存储与迁移

- v2 设置键为 `ask.translation.settings.v2`，包含服务列表、面板位置、最大高度、自动复制和保留内容时间。
- 首次读取时迁移 v1：保留模型引用、本机启用偏好和首选服务商；服务商排在 AI 前，其余服务商不启用。保留原 v1 数据以便回退。
- 旧 `fallsBackToAI` 已移除，不参与迁移或执行。错误只属于对应服务。
- 密钥仍存钥匙串，账号 `translation-provider-<id>`；本机历史可从面板历史菜单清空。
- `AskTranslationLLMService` 将翻译提示词原样发送给选中的模型；删除的模型引用报告不可用，不静默切换。Ollama 使用 OpenAI 兼容 `/v1` 接口。
- 生产实例由 `DIContainer` 的 `translationEngines` 和面板模型注入；面板与启动器共享设置，各自维护可取消的 fanout 会话。

## 服务商适配

`Translation/Providers/` 每家一个 `AskTranslationProviderClient`，负责语言映射、请求、签名、结果解析和错误归类。`AskServiceTranslationEngine` 读取密钥并按上限分块、超时和拼接；空行保留，超长行优先按句末切开。

| 服务商 | 认证 | 单块上限 |
|---|---|---|
| DeepL | `DeepL-Auth-Key`，`:fx` key 走 Free 域名 | 30000 字节 |
| Google | `X-goog-api-key` 请求头 | 5000 字符 |
| Microsoft | `Ocp-Apim-Subscription-Key`，可选地域 | 10000 字符 |
| 有道 | appKey / appSecret，v3 SHA-256 | 5000 字符 |
| 百度 | appid / 密钥，MD5 | 5000 字节 |
| 腾讯云 TMT | SecretId / SecretKey，TC3-HMAC-SHA256 | 5000 字符 |
| 火山翻译 | AK / SK，HMAC-SHA256（V4） | 5000 字符 |

## 验证

相关套件：`AskTranslationFanoutTests`（并行、流式、隔离重试、跳过和取消）、`AskTranslationPolishTests`（双语复制、收起持久化、例句 / 音标、恢复按钮和配置表单）、`AskWordCardTests` / `AskWordCardTranslationTests`（解析、三条例句、提示词和视图），以及面板 / 启动器交互与截图套件。P3 的真机截图和变更覆盖率见 [验证记录](../validation/gul-389/README.md)。
