# Text delivery implementation and acceptance

Date: 2026-09-05
Scope: macOS client. Local development build only; no commit, push, production deployment, or release.

This document describes the current implementation and supersedes the earlier automatic uncertainty-dialog policy in the original audit and proposal.

## Current behavior

- Dictation resolves the current active input at delivery time, including after switching applications or windows. The active caret/selection determines the edit.
- Persona selection rewrites the captured text directly without recording. Explicit selections captured through AX or copy in writable or opaque targets may authorize paste even without an AX range; the original target and exact copied text must be revalidated before write-back. Known non-writable targets remain result-only.
- External applications receive one standard paste. AX is used for target validation and optional observation, not direct external text mutation.
- Typeflux-owned NSTextViews use direct insertion and verify the resulting string.
- Known preflight/dispatch failures show the full result-and-copy recovery dialog. Examples include missing targets, explicitly non-editable controls, changed persona targets, clipboard ownership conflicts, and event creation failure.
- A dispatched paste without reliable AX confirmation does not open a dialog and is never automatically repeated. Output remains in history and the in-memory recovery result. The history message says it was sent but not verified; the apply step uses the existing neutral skipped status, rather than succeeded/failed. Completion analytics records `apply_outcome=unconfirmed`; the server's existing insertion metric only counts `inserted`.

External applications can expose stale or decorative AX text even after a successful edit. Missing or unchanged AX evidence is therefore not sufficient to declare a failed paste. Conversely, dispatch alone is not called verified insertion. If an opaque application ignores the paste without reliable error/evidence, recovery is through history; an automatic failure dialog cannot reliably distinguish that case from successful unobservable insertion.

## Architecture

`TextDeliveryCoordinator` owns ordering, cancellation, results, and awaited cleanup. `AXTextDeliveryBackend` owns native platform operations. `FocusedTextTargetResolver` follows explicit focus with bounded traversal, preserves opaque focused windows, and never substitutes an unfocused editable sibling.

Clipboard capture and delivery share a lease. Persona copy probes finish before the clipboard snapshot. Dispatch validates target identity, range, available raw value, current process, and clipboard ownership. Cleanup survives cancellation and restores only a payload still owned by the transaction.

Positive observation compares the exact expected range edit. `TextDeliveryContent` prefers character-count/range APIs and explicit placeholder metadata over decorated AXValue. This remains best-effort: the observed ChatGPT input also reported the placeholder through its character model. Observation is supplemental evidence, not a gate that forces a recovery dialog after every unverified dispatch.

Results are persisted before delivery. Session checks prevent obsolete completion from replacing newer UI. Pickers preserve source keyboard focus. Native overlay callbacks use a weak owner box retained through main-loop unregistration.

## Confirmed runtime findings

1. Zed exposed only an AXWindow. The initial resolver rejected it before paste. Preserving it as an opaque target enabled insertion, confirmed by the user.
2. The ChatGPT input accepted an AX setter call without visibly committing text. Delivery logs had no paste dispatch while history recorded success. External setters were removed; the user then confirmed successful insertion.
3. Successful insertion still produced an uncertainty dialog. Logs showed placeholder content reported consistently through AXValue, character count, and range text. The fundamental defect was converting unavailable verification into an intrusive recovery dialog. That policy has now been removed for all external applications.
4. A temporary review app and the normal development app had run concurrently. The temporary instance was stopped; final builds target the normal development app.

## Test coverage and review

Tests cover current-target changes, caret/middle/selected replacement, Unicode and whitespace, opaque windows, non-editable targets, original persona authority, one-paste policy, ambiguous/stale/absent observation, known failures, cancellation, clipboard ownership/restoration, old sessions, retained output, overlay callback lifetime, and neutral analytics outcomes.

The key UI regression assertion now requires unverified dispatch to retain the result without showing a dialog or claiming verified insertion. A separate assertion requires known rejection to preserve the recovery dialog. Parameterized observation tests include the reported placeholder-to-generated-text transition and stale values.

The core coordinator's earlier coverage run measured 97.62% line coverage; that number predates the final outcome-policy changes and is not presented as current coverage. Full repository/platform adapter coverage remains below the 90% target. Current full-suite results and packaged startup are recorded below.

## Acceptance limitations

The user has confirmed successful insertion in Zed and the ChatGPT input. The final no-popup policy is covered by workflow tests; final interactive acceptance is still pending.

Computer Use refused access to `com.openai.codex` for safety reasons. No alternative UI access was used to bypass the restriction. Signed packaged startup is checked separately and does not prove microphone-to-editor behavior or universal compatibility. The minimal development bundle does not include Sign in with Apple entitlements.

## Final validation

- Full `swift test`: 2,536 XCTest and 48 Swift Testing tests passed, zero failures. Log: `/tmp/typeflux-delivery-outcome-verified-tests.log`.
- A low-energy retry test previously asserted analytics immediately after the mock insertion callback. It now waits for the actual completion event before checking terminal properties; the final full run passes.
- `make run`: rebuilt and launched `/Users/mylxsw/Applications/Typeflux Dev.app` using the minimal variant. Log: `/tmp/typeflux-delivery-outcome-build.log`.
- `codesign --verify --deep --strict`: passed; one normal development process was observed.
- `git diff --check`: passed. No source changes in the API repository; its existing analytics insertion filter was inspected to verify neutral outcome handling.


## Persona copy-selection follow-up

The successful ChatGPT selection used AX range evidence; copy-backed selections in other editors were systematically classified as result-only because their range or editability was unavailable. This skipped the delivery coordinator entirely. Explicit persona capture now grants paste authority from captured AX/copied source text plus a focused writable/opaque target. It does not relabel unknown AX editability as writable. Ordinary incidental copy capture does not gain this authority.

The existing one-shot context, same-target fingerprint, exact source revalidation (including recopy for copy-backed selections) before the clipboard lease, and pre-dispatch validation remain required. Explicitly non-writable targets, absent copied text, and changed focus remain blocked. An opaque window cannot expose every internal field identity; source recopy and stable target evidence are used without an application-specific allowlist.

New policy tests cover writable/opaque capability with no range and reject read-only, unfocused, missing-source, missing-target and automatic-capture cases. A full workflow test checks that an opaque copy selection is rewritten once, uses the captured context, does not start recording, retains the output, and does not show the result-only dialog.

Persona follow-up final validation: full `swift test` passed 2,537 XCTest and 50 Swift Testing tests, zero failures (`/tmp/typeflux-persona-selection-final-tests.log`). `make run` rebuilt and launched the normal minimal development bundle. Strict signature verification and `git diff --check` passed; one normal development process was observed. Other applications' persona write-back still requires runtime confirmation.

## Sublime role-validation correction

At 23:39:42, live logs confirmed capture authorization was already `verifiedPaste`. Final selection validation rejected it with `text=match`, `frame=match`, `window=match`, but `role=conflict`. The legacy non-editable role list contains AXWindow and other opaque containers, and the fingerprint validator consulted that list before checking equal roles. This contradicted the capability classifier used by capture and delivery.

The validator now uses the shared target capability classifier. Known non-writable roles remain conflicts; identical or compatible opaque roles can proceed only when the source text and identity checks also pass. Parameterized tests compose capture authorization with final validation for every opaque container, both stable and rebuilt element identities with matching frame evidence. Separate tests reject known non-writable roles, changed text, and lost targets.

Full suite: 2,537 XCTest plus 53 Swift Testing tests passed with no failures (`/tmp/typeflux-persona-role-tests.log`). The normal development bundle was rebuilt and launched. Additional focused tests cover the expanded stable/rebuilt identity parameterization.

Computer Use successfully inspected Sublime and confirmed its window-only AX representation. A new unsaved document with synthetic test text was created without editing the user's original tab. Automation pasted the synthetic text successfully, though its own clipboard-consumption check timed out. Its persona key chord was delivered directly to Sublime (opening Sublime's scope popup), not through Typeflux's global hotkey handler. The popup was closed. A physical shortcut invocation was requested to complete runtime persona acceptance; that acceptance is not yet claimed.

Sublime runtime acceptance completed after the user invoked the physical persona shortcut. At 23:51:00 both selection validations reported `accepted=true`, `text=match`, `role=match`, `frame=match`, `window=match`, with captured/current role AXWindow; paste was dispatched. Computer Use then visually verified that the synthetic Chinese sentence had been replaced by its English rewrite, with no remaining original sentence or duplicate insertion. The adapter still reports unconfirmed because Sublime does not expose text-value evidence, but this is distinct from the successful visual verification and does not trigger the automatic uncertainty dialog. The synthetic unsaved test tab remains available; the user's original document was not modified. Focused stable/rebuilt-role tests also passed: 75 XCTest and 23 Swift Testing tests (`/tmp/typeflux-persona-role-focused.log`).
