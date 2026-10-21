# C4 caller audit

This port is a trusted host-internal transport seam. `RegisteredProvider` and the
resolved `TextLLMConfiguration` can contain credential authority. They remain in
host composition and the transport call; they are not runtime advertisements,
serialized state, prompt fields or log fields. No session accessor, global cancel,
network wrapper, retry loop or model-selection authority is added.

| Swift caller | Composition and preserved host checks |
| --- | --- |
| Normal answer | `AskConversationModel.drive` uses its constructor-injected retained client after binding, execution claim/cache, account/run/inference, model/vision, sanitized-memory and context-planning checks. Usage and progress callbacks retain their current owner/identity checks. |
| Queued foreground summary | The same `waiting_inference` branch uses the summary payload's model reference. Its progress remains hidden; its usage remains attached to the inference receipt. |
| Background semantic summary | `AskConversationWindowController.makeAPI` captures the supplied client once in the local engine's summary closure. `AskAuxiliaryInference.complete` retains resolution/planning, the independent capture actor, and failure-to-receipt behavior. Engine preparation/receipt ownership remains unchanged. |
| Automatic local title | `AskConversationModel.scheduleTitle` uses the same retained instance as answers, explicitly passing nil callbacks. Claim, transcript filtering, tool-call rejection, title cleaning, account/deletion/cancellation and title-result validation stay in place. |
| Quick Ask | `submitQuickAsk` enters the conversation submission/drive path with tools disabled. The injected conversation client therefore serves local Quick Ask too. Existing Quick Ask suite covers temporary storage, cancellation and tool rejection. |
| Workflow assistant | `Dependencies.inference` holds the supplied instance. The existing inference path still resolves/plans before the call, passes `onUsage: nil`, guards progress by generation, and checks the current operation before receipt submission. |

`AskCustomInference` directly conforms through the existing provider overload in
`AskProviderInference`. Its profile/key overload, concrete overload defaults,
redirect/credential policy, API styles, provider reasoning and context recovery
remain unchanged. `ProviderModelsView` verification and generic
`ResponsesLLMClient` remain concrete host utilities. Cloud requests continue
through the routed API; unrelated translation/rewrite features are unchanged.

## Bounded Go audit

Read-only checkout: `typeflux-api` at
`b01ff3fdfa9fd309117257c51d4653dd1a435be1`. No Go production change or PR.

- `internal/ask/engine.go:31` and `:63`: title, summary and main model clients
  already use `service.ChatService`; `Store` and `CloudTool` are existing
  interfaces (`model.go:235`, `webtools.go:23`).
- `internal/ask/research.go:86`: nested research calls `e.Chat.CreateChatCompletion`
  under its existing budget/metering context; cloud tool execution stays in the
  host at `:143`. It is not a separately replaceable runtime authority.
- `internal/ask/worker_engine.go:128`: durable binding validation precedes model
  dispatch. Custom models persist `waiting_inference` intent; hosted model work
  uses `requestCompletion` (`:218`), which delegates to `e.Chat` in
  `stream.go:210`/`:214`. Durable begin/checkpoint/finish and lease/run identity
  checks remain host-owned; uncertainty still stops replay.
- `internal/ask/semantic_compaction.go:167`: summary work uses its existing
  `ChatService`. Background admission remains in `summary_background.go`.
- `internal/ask/title.go:217`: automatic title calls `e.TitleChat` under its existing
  claim/result flow. `internal/app/app.go:957`–`:970` composes all three services
  before durable workers can enqueue titles.

Shared runtime-facing model authority, state dispatch, peer negotiation and a
fake alternate-runtime end-to-end path remain later work in the same-stage
backlog sibling GUL-457 (confirmed backlog during this run). C4 does not establish complete runtime replaceability.
