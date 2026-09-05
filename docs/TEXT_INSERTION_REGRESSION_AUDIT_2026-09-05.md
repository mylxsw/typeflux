# Text insertion regression audit and repair proposal

Date: 2026-09-05  
Reviewed client commit: `7bdf2206aa1f5c3c9ad1e597dd256e0895365d0e`

> Planning update: the user's subsequent behavior requirements supersede this report's recommendations to bind ordinary dictation to the initial editor. Ordinary dictation must follow the current external input and caret at delivery time, including intentional app/window changes. Findings below remain historical audit evidence; use [the revised behavior plan](TEXT_INSERTION_BEHAVIOR_PLAN_2026-09-05.md) for the proposed product contract.

## Scope and conclusion

This is an implementation and Git-history audit of the macOS client, not a claim that the reported failures have been reproduced in every affected application. No application source was changed. The client worktree was clean before the audit.

The reported symptoms are consistent with several distinct problems in selection capture, target validation, event delivery, and outcome reporting. The implementation currently has no consistent definition of successful insertion. Ordinary dictation and persona replacement use different transport policies; both live paste paths report success after dispatch without observing delivery. Meanwhile, some captured selections intentionally permit generation but prohibit replacement.

The repair should unify target ownership and result semantics while preserving the different safety requirements of insertion and replacement. Re-enabling the old synchronous verification loop, loosening all selection checks, or increasing every delay would each reintroduce known risks.

Ownership is in `typeflux/`: generated text reaches `WorkflowController.applyText`, which delegates to the local injector. No HTTP, ASR, or billing contract change is proposed. Other repositories were not changed or validated; upstream generation failures are outside this audit's conclusions.

## Current execution paths

### Ordinary dictation

`applyText(replace: false)` → synchronous `TextInjector.insert` → `setText` → resolve the currently focused element → reject a missing/non-writable target → `setTextViaPaste` → preserve clipboard → write output → dispatch Cmd+V → schedule clipboard restoration → return `.inserted`.

The initial selection snapshot is available to the workflow but is not passed to `insert(text:)`. The actual destination is resolved again at completion. The function returns immediately after paste dispatch; it does not verify an edit.

### Persona applied to a selection

Explicit selection capture → AX selected text, or temporary Cmd+C probe → compute replacement safety → generate rewritten text → either show a result-only dialog or dismiss the processing overlay and perform a selection transaction.

The transaction consumes the captured context, validates process/element/text/range evidence, then either writes `AXSelectedText` or posts Cmd+V directly to the captured process. AX success is accepted as committed; paste dispatch is accepted as inserted. Exceptions are converted into a copy-result dialog by `applyText`.

## Findings

### 1. Confirmed whitespace mismatch rejects an unchanged selection

Locations: `AXTextInjector+Selection.swift:99–183`; `AXTextInjector+Transaction.swift:120–181, 442–443`.

`validSelectionText` trims whitespace/newlines and its result is stored in `SelectionContext.selectedText`. At replacement time, the AX path reads the raw selected text. The fingerprint requires exact string equality.

An extracted-source experiment using the current production helper implementations, a stable element, and identical UTF-16 ranges produced:

| Original selection | Captured text | Validation accepts |
|---|---|---|
| `hello` | `hello` | Yes |
| `hello\n` | `hello` | No |
| ` hello ` | `hello` | No |

Thus a full-line or paragraph selection can be rejected although neither focus nor selection changed. This is a deterministic helper-composition defect, not a live-app reproduction. The trimming helper was introduced by `cf11d84` on September 5; this finding alone cannot explain incidents before that change.

Repair: retain exact raw selected text and its UTF-16 range as transaction evidence. Keep any normalized text for generation/display in a separate field. Do not simply trim both sides: a whitespace change can be a real user edit and should not silently authorize replacement of different content.

### 2. Confirmed: dispatch is recorded as successful insertion

Locations: `AXTextInjector+Paste.swift:251–330`; `AXTextInjector+Transaction.swift:533–591`; `WorkflowController+Processing.swift:305–359`.

Both live paste paths return after posting keyboard events. A target that ignores the shortcut, receives it with unsuitable focus, or delays reading the clipboard can leave the editor unchanged while the workflow records `.inserted` and dismisses processing.

Ordinary dispatch also uses optional event creation (`vDown?` / `vUp?`) and cannot report event-construction failure to its caller. The persona path at least guards event construction.

This provides a direct mechanism for “nothing inserted, no recovery action.” It does not prove which target ignored an event in the user's sessions.

Repair: make dispatch return a receipt, not a success assertion. Introduce distinct outcomes for confirmed insertion, target acknowledgement, dispatched-but-unconfirmed, blocked-before-write, and cancellation. Preserve generated output independently of the outcome.

### 3. Confirmed: dictation and persona use different paste transport policies

Locations: `AXTextInjector.swift:614–624`; `SettingsStore+Agent.swift:14–20`; `AXTextInjector+Paste.swift:426–445`; `AXTextInjector+Transaction.swift:549–584`.

Ordinary insertion consults `stubbornPasteFallbackEnabled`, whose default is true, and therefore normally uses HID event dispatch. Persona replacement always uses `postToPid` and ignores that setting. The latest copy-selection code already supports a process-scoped copy followed by a HID copy fallback when the first does not respond.

This is a concrete compatibility asymmetry. Whether it explains a particular application's failure needs a controlled comparison. Copy and paste should not share an indiscriminate retry rule: a second copy is much less dangerous than a second paste.

Repair: use one explicit delivery policy selected from observed target capabilities and tested adapters. Apply it to dictation and selection replacement. Once a write or paste might have happened, do not send a second paste automatically merely because acknowledgement is missing.

### 4. Confirmed: selection capture compatibility does not imply replacement compatibility

Locations: `AXTextInjector.swift:837–1030`; `TextInjector.swift:18–69`; `WorkflowOverlayPresentationPolicy.swift:11–13`.

The September 5 Chromium repair permits explicit actions to capture useful selected text even when AX exposes a collapsed or unavailable range. However, `replacementSafety` still requires a positive range, editability, and focused-target evidence. Otherwise the selection is `.resultOnly` and the workflow deliberately opens a dialog without attempting insertion.

Consequently “the persona ran successfully” and “the result can be replaced in place” are separate capabilities today. Read-only selections should remain result-only. Generic opaque targets cannot be made safely replaceable from Cmd+C success alone, because some apps copy a whole field or line without a selection.

Repair: model context capture and replacement capability separately in both code and UI. For supported web/editor adapters, accept alternative positive selection evidence only when editor/window identity and the still-active selection can be established. Keep unsupported ambiguous selections in a clearly explained result-only mode; never silently convert them to ordinary insertion.

### 5. Confirmed target-ownership gaps; live consequences need reproduction

Locations: `TextInjector.swift:92–99`; `WorkflowController+Processing.swift:335–341`; `AXTextInjector+Transaction.swift:290–306, 392–446, 533–584`.

Ordinary insertion re-resolves the frontmost target at output time instead of binding to the initial editor. Persona replacement has stronger capture-time identity checks, but its last check on the main actor is process identity only. A different field or window in the same process can therefore change after validation and before dispatch. Clipboard snapshot preparation can take up to 250 ms inside that final phase.

The pre-AX validation uses a frontmost PID captured earlier; it does not create an atomic lock on another app's focus. The existing 50 ms overlay dismissal delay is not evidence that the intended editor regained focus.

Repair: capture a session-scoped target for both modes, including process, window and editor identity; capture cursor/selection evidence when available. Before the irreversible action, perform bounded validation of that same target. Distinguish focus lost through Typeflux UI from deliberate user navigation. Do not force focus back after a user switches destinations. Absolute atomicity across an external application is unavailable, so residual races must produce honest outcomes and retained output.

### 6. Clipboard contents affect insertion eligibility and timing

Locations: `AXTextInjector.swift:277–286, 306–308`; `AXTextInjector+Paste.swift:824–925`.

Clipboard preservation reads every available representation, requires completion within 250 ms, and imposes an 8 MiB aggregate limit. A large image or slow promised representation can block an otherwise valid paste before dispatch. This is a deliberate preservation guard, but it creates a hidden dependency on unrelated clipboard contents.

After dispatch, current paths restore the clipboard after 1.5 seconds if its change count is unchanged. This protects later clipboard writes but does not demonstrate that the target consumed the output. A delayed paste-confirmation dialog can outlive that interval. Capture/copy probes and delayed restorations also lack a single transaction owner; change-count checks alone do not express ownership of an in-flight paste.

Repair: introduce a serialized clipboard coordinator with transaction ownership, bounded snapshots, conditional restoration, and explicit cleanup. Prepare preservation work before final target validation. For clipboard payloads that cannot safely be preserved, use an already-authorized native path if supported or retain the result with a specific recovery explanation. Do not silently clear unrelated clipboard contents. Slow or unobservable consumers require a documented bounded policy and recoverable output; extending a fixed delay cannot guarantee delivery.

### 7. Misleading failure dialogs have more than one possible origin

Locations: `AXTextInjector+Transaction.swift:348–389`; `WorkflowController+Processing.swift:351–359`; history of `36e7099` and `272d017`.

The August 29 implementation introduced post-write verification that could classify unavailable/stale readback as failure. Subsequent changes bypassed much of that verification. In the current transaction, an AX timeout/cannot-complete response is still ambiguous: the app may have applied the edit before acknowledgement failed. The injector correctly avoids a second paste but throws, and the workflow maps that to a generic copy-result dialog.

The current live paste paths do not run the old paste-verification loop. A present-day “inserted but failure dialog” cannot therefore be attributed to that loop without establishing the installed build and route. An ambiguous AX write is a current candidate; older build behavior is another.

Repair: represent uncertainty explicitly. Use “Could not confirm insertion; your result is available below” for ambiguous delivery, and a specific reason for a known pre-write block. Do not mark both as “insertion failed.” Keep dialogs until the user dismisses or handles them.

A suspected persona-completion dismissal bug was checked and ruled out: `OverlayController.dismissSoon` explicitly preserves `.resultDialog` and `.notice` at lines 859–875.

### 8. Dead paths and helper-only tests obscure actual behavior

Locations: `AXTextInjector+Paste.swift:15–20, 68–156, 256–261, 295–423`; `AXTextInjector.swift:626–644`.

`setText` rejects replacement, then returns from its ordinary-insert branch. The older AX-write/fallback section below it is unreachable through this method. Similarly, `setTextViaPaste` rejects replacement and returns for ordinary insertion, leaving the later replacement verification branch unreachable. Tests for verification helpers can pass even though production no longer calls that verification path. The strict-verification setting consequently does not govern the new live selection transaction.

Repair: after establishing route-level regression coverage, remove unreachable paths and retire or reconnect settings deliberately. Keep one insertion orchestration layer and separate transport adapters. Test the entry points and actual operation sequence, not only predicates.

## Regression timeline

| Date | Change | Relevant behavior |
|---|---|---|
| Aug 29 | `36e7099` | Added extensive AX/paste delivery verification. |
| Aug 30 | `272d017` | Restored responsive ordinary dictation with eager paste. |
| Aug 31 | `00b1ec7` | Introduced captured selection transactions and background replacement work. |
| Sep 1 | `b981246` | Reworked selection compatibility and eager persona paste. |
| Sep 2 | `e3a949e` | Added evidence-aware identity matching. |
| Sep 3 | `1b45368` | Restored clipboard preservation after insertion. |
| Sep 3 | `a988a27`, `c1ac43f`, `aa4ff2e` | Tightened stale-selection protection, then restored explicit selection capture compatibility. |
| Sep 5 | `cf11d84` | Expanded Chromium capture, distinguished result-only selections, introduced the trimming mismatch described above. |

These are verified source-change dates, not proven introductions of each reported incident. The installed `~/Applications/Typeflux Dev.app` advertises version/build `0.4.0`; its executable modification time is September 5, 16:34:40 local time. Those values do not establish its source SHA or prove that it was the process used during a failure. Future diagnostic records should include a build SHA.

## Proposed implementation sequence

### Phase 1: Correct data and outcome semantics

1. Separate raw selection evidence from normalized prompt/display text; add full-line, indentation, whitespace-only and Unicode range regressions.
2. Make the injector asynchronous for both modes, returning a structured outcome and reason. Clear per-operation method state rather than relying on shared mutable last-method state.
3. Save generated output before attempting delivery. Distinguish generation completion, confirmed application and available-for-copy in history and analytics. Preserve cancellation semantics rather than turning cancellation into a generic insertion error.
4. Keep recovery content available for every blocked or uncertain outcome. Localize the reason-specific messages across supported locales.

### Phase 2: Unify delivery and target ownership

1. Introduce `InsertionRequest` with session ID, operation intent, exact output, captured target and replacement authorization.
2. Introduce a target resolver/validator, native AX writer, keyboard-paste adapter, clipboard coordinator and bounded observer behind injectable protocols.
3. Share transport policy across modes, initially preserving known-working app behavior. Add app-specific adapters only from measured failures, with narrowly scoped capability rules.
4. Prepare reversible work first, revalidate the captured destination, then issue at most one potentially effective delivery action. Permit fallback only when the preceding mechanism is known not to have written anything and authorization remains valid.
5. Remove obsolete restoration/verification branches once the new entry-point tests cover their intended guarantees.

### Phase 3: Observe without freezing or claiming certainty

1. Capture a small baseline on AX-readable editors. Observe the expected UTF-16 edit in the same editor asynchronously, accepting tested editor normalization rules.
2. Bound total observation time and AX traversal work; a per-AX-call timeout alone does not bound a whole traversal. Keep AX probing and clipboard materialization off the main actor where supported; reserve it for AppKit UI/event coordination.
3. Preserve the direct AX acknowledgement as its own evidence level. Treat missing or conflicting readback as uncertainty unless there is strong, target-specific evidence of rejection.
4. Do not use a global clipboard data-provider callback as proof that the intended editor consumed or inserted text. Clipboard managers can request the same data.
5. Emit metadata-only diagnostics: build SHA, session ID, app identifier, operation, capability, transport, reason code, elapsed times, and evidence availability. Existing text-preview log sites should be removed/redacted while revising this path; no selected text, generated text, window titles or clipboard payloads are needed to diagnose route selection.

## Validation and release criteria

The audit ran:

```sh
swift test --filter 'AXTextInjectorTests|TextSelectionSnapshotTests|WorkflowControllerProcessingTests|WorkflowOverlayPresentationPolicyTests'
```

Result: **231 tests passed, zero failures**. This validates the existing selected tests, not real keyboard/AX delivery. The extracted-helper experiment independently demonstrated the whitespace mismatch. No full test suite, coverage run, signed-app insertion smoke test, server test, or deployment was performed for this analysis-only change.

Required implementation tests include transport dispatch with no edit; delayed successful edit; AX timeout after an applied edit; same-process field/window changes; AX element recreation; positive versus absent selection evidence; trailing newline/indentation; UTF-16 emoji ranges; clipboard snapshot timeout/oversize; user clipboard changes; overlapping sessions; cancellation before and after dispatch; and recovery-dialog persistence. Verify no duplicate write, no wrong-target replacement, and no lost generated output in each case.

Use a signed development app and disposable synthetic text for the runtime matrix:

| Target class | Candidate examples | Essential cases |
|---|---|---|
| Native text | TextEdit, Notes | Empty field, caret in middle, full-line replacement, undo |
| Browser | Safari and Chromium | textarea, contenteditable, collapsed/stale AX selection |
| Electron | VS Code and the user's failing Electron app | Editor versus embedded chat, rebuilt AX element, persona picker focus |
| Custom editor | User-reported app; Zed if relevant | Opaque AX target, process/HID behavior |
| Terminal/panel | Terminal, iTerm2, launcher field | Multiline paste confirmation, slow consumer, temporary window focus |
| Read-only target | Web article selection | Generate context result without destructive write-back |

Add large clipboard data, an active clipboard manager, rapid repeat sessions, intentional app/window switching and cancellation. Test direct persona hotkeys and mouse selection in the picker separately. The exact failing app/textbox list remains to be supplied.

Before release, run the full client suite and coverage required for core-workflow changes, then compare signed builds around the relevant timeline boundaries on the same target apps. Embed the source SHA, record per-app outcomes and latency, and verify that recovery UX does not generate false failure claims. Do not label the product regression fixed from unit tests alone.
