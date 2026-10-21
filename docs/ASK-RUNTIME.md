# Ask application boundary

`AskApplicationAPI` is the application's `AskAPI` entry point. It receives three independent, Sendable services:

- `AskAgentRuntime` owns send, tool/inference results, cancel, observe, retry, regenerate, steer and resume.
- `AskConversationAccess` owns history reads, listing, titles, deletion, keeping temporary conversations and memory purging.
- `AskModelAccess` owns feature catalogs, model lists and usage.

The conversation window and the workflow editor's fallback construct this facade with `AskApplicationAPI.routed(cloud:local:)`. That factory shares the existing `AskRoutedAPI` across the three capabilities. Empty tokens still route locally; signed-in tokens route to Cloud. Memory purging retains the router's local-plus-Cloud semantics, including source ownership. Existing callers and engines can keep implementing the compatibility composition `AskAPI`.

A replacement runtime only implements `AskAgentRuntime`; inject it alongside the existing conversation and model services using `AskApplicationAPI(runtime:conversations:modelAccess:)`. The facade explicitly forwards every runtime requirement, including `observe` and `resume`, so those calls always reach the injected runtime rather than the separate history dependency. No concrete engine casts are needed.

The existing polling `observe` and history-reading `resume` defaults depend on `conversation`. As approved in the Step 1 contract supplement, their unchanged bodies live in `extension AskAgentRuntime where Self: AskConversationAccess`. Existing `AskAPI` fakes retain these defaults; a runtime-only implementation must supply its own observation and resume behavior. Other defaults retain their existing behavior in the corresponding capability's extension.

This is an application seam, not a completed engine decomposition. The default local and Cloud engines still implement `AskAPI`. Request/response types, persistence, token routing, prompts, tool permissions and cancellation semantics are unchanged. There is no adapter selection UI, active-run binding, new framework or persistence migration in this step.
