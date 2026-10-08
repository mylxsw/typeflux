# 翻译引擎：单独的翻译模型与翻译服务商

> 状态：已实现（GUL-255）。设置位置：「设置 → 启动器 → 翻译」。

## 目标

翻译不再只能用「本机 Translation → 文本处理模型」：

1. 可以给翻译单独选一个大模型（AI 翻译和生成单词卡都用它），不影响语音改写。
2. 可以接入翻译服务商：DeepL、Google、Microsoft、有道、百度、腾讯云、火山翻译。

## 引擎选择（`AskTranslatePlugin.plan`）

1. 关键词或 ⌘R 指定了 `engine`：`ai` 走 AI；服务商（如 `engine=deepl`）即使本机能翻也用它。
2. 单词本里已有这个词的卡片 → 单词本。
3. 「本机能翻时优先用本机」打开，且本机能翻这对语言 → 本机（可以边输入边翻）。
4. 否则使用「首选翻译引擎」：AI 大模型，或某个服务商。

隐私规则不变：除了本机和单词本，AI 和服务商都要按 ↩ 后才发送（`.onSubmit`）。
服务商失败（没填密钥、密钥错误、额度用完、网络问题、不支持的语言）且打开了「服务商失败时改用 AI」时，
改用 AI 翻译，卡片上注明原因；关闭时显示服务商的错误。用户取消不会触发回退。
单词卡始终由 AI 生成；服务商翻译单词后，⌘R 仍可生成单词卡。

## 配置

- `AskTranslationSettings`，存在 UserDefaults 的 `ask.translation.settings.v1`：首选引擎、翻译模型引用
  （空 = 跟随文本处理模型）、是否优先本机、失败时是否改用 AI。默认值与改动前的行为一致。
- 密钥只存钥匙串，账号 `translation-provider-<id>`（`AskKeychainTranslationCredentials`）。
- 翻译模型：`AskTranslationLLMService`。没选模型时继续用原来的文本处理模型；选了模型时用
  `OpenAICompatibleLLMService(configuration:sendsPromptsAsWritten: true)`，不再拼接听写用的语言策略和环境上下文；
  选中的模型被删除时提示「翻译模型已被删除」，不会悄悄换成别的模型。

## 服务商适配（`Translation/Providers/`）

每家一个 `AskTranslationProviderClient`：语言代码映射、构造（并签名）请求、解析结果、错误归类。
`AskServiceTranslationEngine` 负责读取密钥、按服务上限分块（空行原样保留，超长行优先在句末切开）、超时和拼接。

| 服务商 | 认证 | 单块上限 |
|---|---|---|
| DeepL | `DeepL-Auth-Key`，`:fx` 结尾的 key 走 Free 域名 | 30000 字节 |
| Google | `X-goog-api-key` 请求头（key 不进 URL） | 5000 字符 |
| Microsoft | `Ocp-Apim-Subscription-Key`，可选地域 | 10000 字符 |
| 有道 | appKey + appSecret，v3 SHA-256 签名 | 5000 字符 |
| 百度 | appid + 密钥，MD5 签名 | 5000 字节 |
| 腾讯云 TMT | SecretId/SecretKey，TC3-HMAC-SHA256，默认地域 ap-guangzhou | 5000 字符 |
| 火山翻译 | AK/SK，HMAC-SHA256（V4），默认地域 cn-north-1 | 5000 字符 |

## 测试

`AskTranslationServiceTests`（各服务商的请求格式、签名对照值、错误映射、分块）、
`AskTranslationRoutingTests`（引擎路由、回退、取消、关键词指定服务、设置面板模型、关键词编辑）。
签名对照值由独立的 Python 实现算出；百度用的是官方文档示例。
