> GUL-249 update: the chat UI now uses Strict, Standard (default), and YOLO
> permission modes. The exact-call store below remains the dispatch boundary;
> Standard and YOLO mint fresh single-use grants instead of reusing a prior call.
> See [tool-permission-modes.md](tool-permission-modes.md) for current behavior.

# Scoped device-tool approvals (GUL-168 / P02)

The previous conversation permission authorized a tool name up to a risk tier.
A browser navigation could therefore authorize later clicks or form submission.
Device tools now pass through `AskToolPolicy` and a trusted, in-memory
`AskApprovalStore`. No legacy grants are imported.

## Authorization boundary

Every grant binds the authenticated owner, conversation, action, target, exact
UTF-8 argument digest, tool definition/version and (for MCP) registry server ID
and connection version. Single-use grants also bind run, step and call IDs.
Validation and consumption are synchronous on the main actor. Grants expire
after five minutes, and remain revocable during asynchronous dispatch preparation.
Stop, account reset, deletion and steering invalidate conversation grants.
UI callbacks carry a random approval ID, so an old card cannot approve a newer
request, even when tool call IDs are reused.

`allowed_arguments` has no supported constraint language yet. Any non-null
constraint is rejected, including one accompanied by a matching argument hash.
There are no prefix paths, wildcard domains or argument-subset grants.
SHA-256 covers the original argument string before JSON parsing; whitespace and
key order changes need a fresh approval.

`AskConversationModel` obtains evidence from `AskToolExecuting`, never from model
output or a conversation's harness envelope. After approval it fetches the live
pending call and compares the entire call, preserves the existing execution
journal claim, re-resolves executor evidence, consumes the grant, and dispatches
with a revocation/owner/expiry check. Changed evidence fails closed. A claimed
execution is never automatically replayed if its result is unknown.

Memory writes, file writes/edits, code execution, and MCP calls share this entry
point. Generic click, type, fill, key/hotkey, drag, arbitrary MCP operations and
all writes are single-use. External MCP read-only/destructive annotations never
lower the locally assigned risk. Loading instructions remains automatic, and
submitted screenshot consent still applies only to screenshot calls from that
submission; both use a fresh scoped grant at dispatch.

## Trusted target evidence

| Executor | Binding and revalidation |
|---|---|
| Files | Authorized canonical path, file identity/size/modification stamp, and current root configuration. A symlink switched while approval is pending cannot redirect the grant. |
| Memory | Current local memory owner, action and exact arguments, plus the conversation's authenticated owner. |
| Code | Analysis workspace/conversation, executor definition and exact language/code/timeout arguments. P01's sandbox availability gate remains authoritative. |
| MCP | Local registry UUID, connection generation, definition digest, and a fresh revision on every accepted tools/list. Even schema keywords omitted by an older codec invalidate an outstanding grant when the list refreshes. Registry dispatch checks the identity again. |
| Browser | Browser, window, tab, URL and document time origin. The AppleScript dispatch rechecks these values and addresses the approved tab object instead of following frontmost focus again. |
| Desktop | Bound process launch time, AX window identity, display and window bounds. Validation repeats after activation and between input batches; coordinates outside the approved window are rejected. Interrupted drags release the mouse button. |

Browser and desktop grant reuse remains disabled by the executor, pending P09's
observation contract. Browser document evidence uses the existing AppleScript/JS
adapter; it is not a tamper-proof observation token from a hostile page. This
change does not claim to verify business effects or infer the account selected
inside an arbitrary external application. Missing native identity/permissions
fail closed. P09 owns stronger observation freshness and effect reporting.
File approval checks do not replace a descriptor-based filesystem sandbox:
adversarial replacement during the filesystem operation remains outside this
approval module's guarantees.

## Compatibility and rollout

Production defaults to per-call approval. Reuse requires an explicit local flag
and a trusted peer advertisement injected by the integration owner. There is no
new advertised capability or automatic negotiation in this PR. A decoded v1
conversation envelope cannot enable reuse. Under explicit negotiation, an
executor may offer exact read/navigation reuse in the same conversation for at
most five minutes; changed arguments/target/identity still prompt again.

Public P00 DTOs and wire fixtures are unchanged. P06 can preserve additional MCP
schema/content fields without changing these policy types; its output adapter
must remain shared by both raw and approved MCP dispatch. P09 can replace target
evidence through the executor binding without widening grants. A rollback must
retain per-call approval and must not restore the old risk-tier grant map.

No new diagnostic log contains arguments, targets, content or raw hashes. Grant
IDs are random, and all sensitive binding evidence stays in process memory.
The approval UI intentionally shows the action, target and bounded content
preview to the approving user; this is not diagnostic logging.
