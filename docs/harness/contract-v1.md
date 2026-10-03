# Harness contract v1 (GUL-166 / P00)

Frozen on 2026-10-03. Integration owner for **both** Swift DTOs and Go wire DTOs: **Arch/GPT-Astra**. Changes to names, meanings or fixtures require a coordinated PR pair and an explicit compatibility review by this owner. P02/GUL-168, P06/GUL-173 and P09/GUL-175 consume this contract; they must not independently rename its fields.

This is an additive interface freeze and executable compatibility harness. It does **not** implement a policy engine, typed-content rendering, target validation, project execution, budgeting or recovery. No runner loop, DI registration, migration or production capability switch changes in P00. Existing capabilities remain as before, including the outstanding findings in `acceptance.md`.

## Placement and wire format

- Swift: `Sources/Typeflux/Ask/AskHarnessContract.swift`; Go: `internal/ask/harness_contract.go`.
- `Conversation.harness` and `ResultRequest.harness` (Swift `AskConversation` / `AskToolResultRequest`) are optional envelopes. Old snapshots and requests omit them. A missing envelope is legacy v0, with **no new capabilities**. No backfill is required.
- P00 codecs accept and round-trip this metadata. The current engine does not consume the result envelope or produce capability advertisements. Successful JSON binding is **not** negotiation, authorization, persistence of result metadata or proof of feature support. GUL-173 must add end-to-end request → message → store → stream → provider plumbing before advertising typed content.
- The envelope contains `version: 1`; all fields other than `version` are optional. A present nested object must meet the corresponding field contract. DTOs are storage types, not input validators; consumers must validate required identities, sizes and invariants before execution.
- JSON field names use snake_case. Opaque content/argument objects retain their original keys, including camelCase MCP keys and vendor metadata. Dates are RFC3339 UTC; fixtures use whole seconds so Swift/Go encoding is semantically identical. IDs and revisions on references are opaque case-sensitive strings. Existing conversation UUID normalization remains unchanged.
- Unknown capabilities, versions and outcome values never enable execution. Unknown typed content objects retain their entire JSON representation; other unknown metadata fields may be ignored by older codecs. Explicit null and absent optional fields are equivalent. Empty optional collections may be omitted by Go.

## Capability negotiation

The only v1 known names are `scoped_approval_v1`, `typed_content_v1`, `observation_target_v1`, and `workspace_refs_v1`. `permits` / `Permits` requires version 1 on both peers, the requested name in both capability lists, and an explicit local rollout flag. Its default rollout list is empty. Capability negotiation is a feature gate, **not a policy grant**.

Future integrators must use trusted peer advertisements pinned to the run. A user/model-supplied conversation envelope cannot advertise trusted server capability. Local mode must also supply an explicit executor-side advertisement; `peer = nil` never assumes support. Legacy tool-name grants are not upgraded to scoped approvals.

| Client | Server/executor | Required behavior |
|---|---|---|
| Old | Old | Existing string content, optional image and `is_error`; no envelope |
| Old | New | Existing fields remain readable; no new behavior without client opt-in |
| New | Old/absent advertisement | Gate is false; retain legacy path for compatible operations, otherwise show unsupported capability before dispatch |
| New | New, local switch off | Decode metadata; no new execution |
| New | New, both support + explicit switch | The owning feature may execute only after separate policy/target checks |
| Any | Unknown capability/version | Preserve readable history where possible; gate stays false |

For a legacy result, exact text and one existing image can use the old fields. Multiple images, audio, resources and unknown blocks cannot be silently reduced to successful text. Either reject before dispatch or provide an explicit incomplete/unsupported error (`is_error: true`). `current-result.json` demonstrates the latter conservative projection; it is a fixture, not a newly enabled adapter. An unknown side effect must remain unresolved and must never be automatically replayed because the old server cannot represent it.

## Frozen objects

Fields below without “optional” are required by the semantic contract when that object is present.

| Object | Fields and invariants |
|---|---|
| Envelope | `version`; optional `capabilities`, `context`, `approval`, `outcome`, `observation`, `workspace`, `process`, `artifacts`, `budget`, `recovery_class` |
| ExecutionTarget | `kind`, `id`; optional `version`, `path`, `domain`. Initial kinds: `workspace`, `browser_tab`, `desktop_window`, `mcp_server`, `network_origin`. No consumer may interpret an unknown kind as a broader target. Paths/domains are constraints, never evidence that canonicalization or connection checks ran. |
| ExecutionContext | `owner_id`, `conversation_id`, `run_id`, `step_id`, `tool_call_id`, `tool_name`, `tool_version`, `arguments_hash`, `target`, `deadline`; optional `server_id`, `server_version`, `approval_id`, `idempotency_key`. MCP identity must include stable server identity/version; renaming a display label must not transfer grants. The authenticated owner, not the payload, is authoritative. |
| ApprovalScope | `id`, `owner_id`, `conversation_id`, `action`, `target`, `expires_at`, `single_use`; optional `arguments_hash`, `allowed_arguments`, `consumed_at`, `revoked_at`. At least one argument constraint is required for execution; if both exist, both apply. `allowed_arguments` is an opaque constraint object, not executable code; unsupported constraints deny. Expired/revoked/consumed single-use scopes deny. Consumption must be atomic in the eventual policy implementation. Session scope is `conversation_id`, not a global tool-name grant. |
| ExecutionOutcome | `status`; optional ordered `content` objects, `artifacts`, nonnegative `duration_ms`, `event_dispatched`, `effect_verified`, `truncated`. Status names are `ok`, `denied`, `invalid`, `timeout`, `cancelled`, `unknown`. `ok` describes executor completion, not verified business effect. Missing evidence is unknown, not false proof. Unknown strings retain their wire value but `safeStatus` returns `unknown`. Runtime errors with unverified side effects use `unknown`; do not overload old run lifecycle states. |
| ObservationRef | `id`, `target`, `captured_at`; optional `app_id`, `process_instance_id`, `pid`, `window_id`, `display_id`, `browser_id`, `tab_id`, `document_generation`, `invalidation_reason`. Desktop validation requires process-instance/window identity; browser validation requires browser/tab/document generation. Timestamp freshness alone is insufficient. A navigation/focus/target mismatch requires a new observation. |
| WorkspaceRef | `id`, `owner_id`, `conversation_id`, `run_id`, `version`, `cleanup`. Versions bind file/diff operations; paths are resolved through the owned registry, not accepted from reference strings. |
| ProcessRef | `id`, `owner_id`, `conversation_id`, `run_id`, `workspace_id`, `instance_id`, `started_at`, `cleanup`; optional `pid`, `process_group_id`. A PID is diagnostic only. The launcher assigns an unguessable instance identity and validates it on control/cleanup to avoid PID reuse. |
| ArtifactRef | `id`, `owner_id`, `conversation_id`, `run_id`, `version`, `media_type`, nonnegative `size_bytes`, lowercase hex `sha256`, `cleanup`; optional `expires_at`. Resolve through authenticated artifact delivery. An internal filesystem path is never a delivery URL; this contract exposes neither raw paths nor bearer URLs. |
| RunBudget | `limits`, `used`, `reserved`: maps of nonnegative integer amounts. Reserved names: `steps`, `tool_calls`, `input_tokens`, `output_tokens`, `wall_time_ms`, `microcredits`. A missing limit is unspecified, not unlimited permission. Later R02 owns enforcement and aggregation. |
| recovery_class | Optional `recompute`, `query_idempotency`, `manual_reconcile`. Unknown/missing classes require reconciliation for side effects. P00 adds no recovery execution. |

`arguments_hash` is `sha256:` followed by lowercase hex SHA-256 of the **exact UTF-8 bytes** of the submitted function arguments string, before reparsing. This deliberately avoids incompatible ad-hoc JSON canonicalizers. A whitespace/key-order change requires a new hash and approval, unless a separately validated parameter constraint permits it. This is distinct from an idempotency key: approval does not prove an operation has not already run. Do not log raw hashes of potentially low-entropy secrets.

Cleanup values initially include `on_run_end`, `terminate_group`, `retain_until_expiry`, `user_managed`. Unknown values require reconciliation and never imply permission to delete user data. These references reserve stable identities; they do not promise arbitrary descendant-process isolation or an artifact service in P00.

## Typed content

`content` is an ordered array of opaque JSON **objects**, each with a `type` discriminator. Text, image, audio, resource_link, embedded resource and unknown future blocks survive round-trip. Preserve all images, annotations, `_meta`, resource metadata, booleans, integers and unknown keys. Swift uses existing `JSONValue`; Go uses `json.RawMessage`. No schema narrowing is introduced. P06 must separately validate limits, MIME support, untrusted resource access and explicit unsupported UI before using blocks. Transport preservation does not mean audio/resource execution is supported.

## Fixtures and ownership

`fixtures/` is byte-identical in both repositories. `manifest.json` pins SHA-256 of each fixture. Both test suites verify every manifest entry, negotiation outcomes, three mode descriptors, legacy decoding, raw typed content, and references. Update both copies together; run `diff -r typeflux/docs/harness/fixtures typeflux-api/docs/harness/fixtures` from the workspace. There is no runtime cross-repository dependency.

Mode fixtures distinguish **Local + custom inference**, **Cloud + cloud inference**, and **Cloud + custom inference**. They test DTO/routing descriptors, not actual models or desktop actions. Existing routed-engine and HTTP tests remain the behavioral baseline. The interop fixtures exercise codecs and gates against legacy field subsets; P06 still owes negotiated end-to-end typed-content delivery.

## Logging and coverage policy

Allowed diagnostics: random correlation IDs for run/step/call, capability/version, mode, status, elapsed time, counts, truncation and cleanup reason codes. Treat even IDs as access-controlled diagnostics. Never log prompts, memory, tool arguments/output, typed binary/base64 data, absolute user paths, cookies, Authorization headers, API/database credentials, connection URLs, signed download URLs, or raw argument hashes. Replace sensitive values with `[REDACTED]`; use random event IDs instead of hashing secrets. Test artifacts use synthetic owners, reserved `.invalid` domains and disposable local database credentials. Scrub logs before attaching them; do not attach local profile/environment dumps.

Report command, commit, OS/toolchain/database version, executed/pass/fail/skip counts and failure ownership. Go coverage uses instrumented **statements**, Swift llvm-cov uses **executable lines** (regions/functions reported separately). New core helper code targets >=90%; report DTO synthesized-code limitations. Go full floor remains the existing 80.0%, with strict 90% reported separately. Swift full baseline includes GUI/platform files and is not the new-module target. Never count a skipped integration test, a prior report or a fixture-only mode check as real environment acceptance. Compare identical filters and denominators; retain baseline failures.

Merge compatible API first, then client; enable each feature only in its owning task after combination acceptance. Reverting P00 drops metadata support and tests; it must not be presented as a safe rollback of future enabled policy or side-effect behavior.
