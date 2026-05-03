# Automatic Vocabulary Collection — Design Document

This document describes the overall design, key implementation details, current issues, and recommended fixes for Typeflux's "automatically add vocabulary terms" feature.
This document covers analysis and recommendations only; it does not contain any code changes.

---

## 1. Feature Goal

After a user inserts dictated text into a host application and then makes minor manual edits (e.g., changing `type flux` to `Typeflux`, or `Open AI Realtime` to `OpenAI Realtime`), Typeflux aims to:

1. Observe the user's final text changes in that input field over a short period of time;
2. Use an LLM to determine whether newly appearing "words" are worth adding to the speech recognition vocabulary;
3. Write qualifying terms into `VocabularyStore`, so that future dictation sessions can use them as prompt/hints to improve recognition accuracy.

The entire pipeline runs **entirely in the background with no explicit user action**, controlled by the master switch `automaticVocabularyCollectionEnabled` (enabled by default).

---

## 2. Architecture Overview

```
applyText()
   └── textInjector.insert / replaceSelection   (AX / paste fallback)
   └── scheduleAutomaticVocabularyObservation(for: insertedText)
            │
            ▼
       Task (observation session)
            ├── readInitialEditableSnapshot()          // check that the current focus is editable
            ├── automaticVocabularyStartupDelay (600ms)
            ├── readAutomaticVocabularyBaselineWithRetry()   // capture baseline
            ├── polling loop (interval=1s, window=30s)
            │     ├─ textInjector.currentInputTextSnapshot()
            │     ├─ verify focused app has not changed
            │     ├─ observe(text, state) → update latestObservedText / lastChangedAt
            │     └─ shouldTriggerAnalysis? (idleSettleDelay = 8s)
            ▼
       runAutomaticVocabularyAnalysis(insertedText, baselineText, finalText)
            ├── AutomaticVocabularyMonitor.detectChange
            │       (oldFragment / newFragment / candidateTerms)
            ├── changeIsJustInitialInsertion?   → skip
            ├── isEditTooLarge? (ratio > 0.6)    → skip
            ├── evaluateAutomaticVocabularyCandidates
            │       → LLMRouter.completeJSON (structured JSON schema)
            ├── parseAcceptedTerms
            └── addAutomaticVocabularyTerms → VocabularyStore.add(source:.automatic)
                   └── overlayController.showNotice
```

Key source files:

- [Sources/Typeflux/Workflow/AutomaticVocabularyMonitor.swift](Sources/Typeflux/Workflow/AutomaticVocabularyMonitor.swift) — Pure algorithm layer: diff, tokenization, edit ratio, JSON parsing, candidate/accepted-term validation
- [Sources/Typeflux/Workflow/WorkflowController+AutomaticVocabulary.swift](Sources/Typeflux/Workflow/WorkflowController+AutomaticVocabulary.swift) — Orchestration layer: scheduling the observation task, polling AX, invoking the LLM, persisting results
- [Sources/Typeflux/Workflow/WorkflowController+Processing.swift:273](Sources/Typeflux/Workflow/WorkflowController+Processing.swift) — Schedules observation after a successful `applyText`
- [Sources/Typeflux/Settings/VocabularyStore.swift](Sources/Typeflux/Settings/VocabularyStore.swift) — Vocabulary store (UserDefaults + JSON)
- [Sources/Typeflux/LLM/PromptCatalog.swift:303](Sources/Typeflux/LLM/PromptCatalog.swift) — `automaticVocabularyDecisionPrompts`
- [Sources/Typeflux/Settings/SettingsStore.swift:475](Sources/Typeflux/Settings/SettingsStore.swift) — Toggle `automaticVocabularyCollectionEnabled`

---

## 3. Key Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `automaticVocabularyObservationWindow` | 30 s | Maximum observation duration per session |
| `automaticVocabularyPollInterval` | 1 s | Interval for polling AX accessibility values |
| `automaticVocabularyStartupDelay` | 600 ms | Delay after insertion before reading the baseline |
| `automaticVocabularyBaselineRetryDelay` | 400 ms | Delay between baseline-read retries |
| `automaticVocabularyBaselineRetryCount` | 6 | Number of baseline-read retries (up to ~2.4 s total) |
| `automaticVocabularyIdleSettleDelay` | 8 s | If no new changes for ≥ 8 s after the last edit, the text is considered "stable" and observation ends early |
| `automaticVocabularyEditRatioLimit` | 0.6 | If `(Levenshtein(baseline, final)) / insertedLen > 0.6`, the edit is classified as a "large rewrite" and skipped |

Candidate and accepted-term validation rules:

- Latin/numeric tokens: length ∈ [4, 32], must contain at least one letter; pattern `[A-Za-z0-9]+(?:[._+\-'][A-Za-z0-9]+)*`
- CJK tokens: length ∈ [2, 12]
- Post-LLM acceptance filter: `^[\p{Han}A-Za-z0-9](?:[\p{Han}A-Za-z0-9 ._+\-/']{0,38}[\p{Han}A-Za-z0-9])?$`

---

## 4. Implicit Assumptions in the Current Implementation

1. Within ~600 ms after insertion, the host app's AX value should stably reflect the inserted text; if it does not, `expectedSubstring`-based retries (up to ~2.4 s) serve as a safety net.
2. The user's edits occur within the same focused element and the same app; if focus changes (bundleId/pid/processName mismatch), the session is immediately abandoned.
3. The user will remain **idle for 8 s** after editing to allow the observation window to close; otherwise observation is forcefully terminated after a maximum of 30 s.
4. The size of the edited text is comparable to the size of the dictated text (edit ratio ≤ 0.6); otherwise it is classified as a "major rewrite" and skipped.
5. Only one observation session runs at a time — a new `scheduleAutomaticVocabularyObservation` call cancels the previous task.
6. The host app's `focusedElement()` AX value updates as the user edits manually (otherwise `final == baseline`, equivalent to no change at all).

---

## 5. Identified Potential Failure Modes (Ranked by Likelihood)

### 5.1 Consecutive Dictation Cancels the Previous Observation Session ★★★★

[WorkflowController+AutomaticVocabulary.swift:12-13](Sources/Typeflux/Workflow/WorkflowController+AutomaticVocabulary.swift)

```swift
automaticVocabularyObservationTask?.cancel()
automaticVocabularyObservationTask = nil
```

`scheduleAutomaticVocabularyObservation` unconditionally cancels the previous session at the beginning of the function. This means:

- User dictates at time A → text is inserted → observation session 1 starts (maximum 30 s)
- User presses the hotkey again within the same observation window (under 30 s) for a second dictation → text is inserted → **session 1 is immediately canceled, and its analysis never runs**

For users who frequently dictate short phrases in quick succession and then make minor edits (i.e., the vast majority of real-world use cases), session 1 almost never has a chance to complete the 8 s idle period or the 30 s window. Result: **even though the user genuinely edited the text, the vocabulary remains empty**.

This is the failure mode most consistent with user feedback ("I've been using it for a long time and no terms have been automatically added").

### 5.2 Many Host Apps Have Unreadable AX Values ★★★★

In [AXTextInjector.swift:383-497](Sources/Typeflux/TextInjection/AXTextInjector.swift), the `readCurrentInputTextSnapshot` method returns `text == nil` in all of the following cases:

- `AXIsProcessTrusted() == false` (Accessibility permission not yet granted)
- No `focusedElement` exists
- The focused element is not editable (`isEditable == false`)
- `kAXValueAttribute` cannot be read (Electron apps, contenteditable elements, the Chrome address bar, and certain rich-text views all fall into this category)
- The AX value equals a placeholder or title string

Consequences:

- If the initial snapshot is unreadable → `readInitialEditableSnapshot` waits 400 ms and retries once; if still unreadable the entire session is abandoned;
- If the baseline is unreadable → `baselineText` is `nil`, and the session aborts immediately;
- If the baseline is readable but does not contain `expectedSubstring` → after 6 retries it returns with a "stale baseline" result; if the final text differs too much from this stale baseline, `isEditTooLarge` skips the analysis.

Typical apps with unstable or unreadable AX values: Slack, Discord, VS Code, Chrome contenteditable elements, Logseq, Notion, Obsidian, and other Electron/custom-rendering apps. If the user primarily edits within these apps, **the observation session exits almost every time at the `readInitialEditableSnapshot` or baseline-reading stage**.

### 5.3 Paste Fallback Path Causes Focus/AX Timing Issues ★★★

[AXTextInjector+Paste.swift:8](Sources/Typeflux/TextInjection/AXTextInjector+Paste.swift) falls back to a clipboard-paste path when direct AX writing fails. The paste workflow involves:

- Temporarily writing to the clipboard → sending ⌘V → waiting for the app to process → restoring the clipboard

During this process:

- `scheduleAutomaticVocabularyObservation` is called **synchronously** at the end of `applyText`, but the paste path itself is asynchronous;
- The task immediately calls `readInitialEditableSnapshot`, but focus may still be in a transient state during the clipboard restoration;
- The 600 ms startup delay is too short for some apps — the baseline still reflects the pre-insertion state, the `expectedSubstring` check fails, and after retries the session falls into the "stale baseline" branch.

Combined: the observation session has weaker robustness when the paste path is used.

### 5.4 Overly Strict Length Threshold Filters Out Candidate Terms ★★★

`isValidLatinOrNumberToken` requires **≥ 4 characters**, so the abbreviations that users are **most likely to correct** — `GPT`, `API`, `iOS`, `AI`, `ASR`, `LLM`, `AST`, `AX`, `UI`, `gRPC`, `npm`, `pip`, `YAML` — are all discarded by the diff algorithm. Even if the user changes `A.I.` to `AI` or `api` to `API`, these tokens never enter the candidate list and can therefore never be added to the vocabulary.

The CJK requirement of ≥ 2 characters is reasonable; however, the 4-character minimum for English technical terms is overly conservative.

### 5.5 "Normalized New Fragment Equals Inserted Text" Check Is Too Aggressive ★★

[AutomaticVocabularyMonitor.swift:204-215](Sources/Typeflux/Workflow/AutomaticVocabularyMonitor.swift) `changeIsJustInitialInsertion`:

```swift
if normalizedNew == normalizedInserted { return true }
let insertedTokens = Set(tokenize(insertedText).map(normalize))
return change.candidateTerms.allSatisfy { insertedTokens.contains(normalize($0)) }
```

- The first check (exact equality) prevents a baseline-capture lag from treating the entire newly inserted text as a "user edit." This is fine.
- The second check (all candidate tokens appear in insertedText's token set) is more aggressive. Scenario: the user dictated "OpenAI," but it was misrecognized as "Open AI"; after insertion, the user manually removed the space to merge it into "OpenAI." After editing, `newFragment = "OpenAI"`, candidate = `["OpenAI"]`, and `tokenize("Open AI")` (was the text given to `insertText` the recognized "OpenAI" or "Open AI"?) — this depends on the specifics.

A more common scenario: the user dictates "typeflux," which is recognized as "type flux" (two words); the inserted text is "type flux" (`insertedText`). The user changes it to "Typeflux." In this case, `insertedTokens = {"type", "flux"}` ("flux" at 4 characters just passes the threshold), `candidateTerm = "Typeflux"`, normalized = "typeflux" ∉ {"type", "flux"} → it will **not** be filtered out. **This check is safe in most cases**, but when combined with §5.4 it significantly reduces recall.

### 5.6 Edit Ratio Threshold of 0.6 Is Strict for "Delete + Rewrite" Scenarios ★★

If the user's edit consists of "deleting an entire fragment from the baseline and rewriting it" (common when replacing a verbose expression), the Levenshtein distance can easily exceed 60% of the inserted text length, triggering `analysis skipped: edit too large`. For very short dictations (< 20 characters), the threshold effect is especially pronounced.

### 5.7 LLM Decision Prompt Is Overly Conservative ★★

The `automaticVocabularyDecisionPrompts` instructions include:

- "If uncertain, return an empty list."
- "Prefer precision over recall"
- A lengthy rejection list

Given the already small pool of candidate terms, the LLM frequently returns `{"terms": []}` simply because it is "uncertain." Combined with §5.4 and §5.6, the end-to-end probability of new terms being added is further suppressed.

### 5.8 No User-Visible Feedback When Observation Produces No Results ★

The entire pipeline only outputs logs via `NetworkDebugLogger.logMessage("[Auto Vocabulary] ...")`; there is **no user-visible status indicator**. Users have no way to distinguish between:

- Whether the feature is actually enabled (though it defaults to `true`)
- Whether the focused app is on a blacklist or has unreadable AX values
- Whether the session was canceled by a new dictation
- Whether the LLM rejected all candidates

This is the meta-reason why users cannot self-diagnose the issue.

### 5.9 Unlikely Edge Case: Data Written but Not Read Back ★

`VocabularyStore.add` → `save` → `UserDefaults.set` is synchronous, and `load()` immediately reads back the data correctly. From the code, the data path itself is sound — unless multiple processes write to UserDefaults simultaneously (which does not happen since the application is single-process). You can verify by inspecting the `vocabulary.entries` key in `~/Library/Preferences/com.typeflux.plist`.

---

## 6. Recommended Troubleshooting Steps (No Code Changes Required)

1. **Check the logs**: Typeflux prints the complete event stream with the `[Auto Vocabulary]` prefix. Open Console.app or capture recent dictation + edit sessions via `make dev` terminal logs to see exactly which stage the flow breaks at — `session scheduled / session aborted / analysis skipped / llm decision received`.
2. **Inspect UserDefaults**: Run `defaults read com.typeflux vocabulary.entries` (or read the plist file) to check whether any entries with `source: automatic` exist.
3. **Identify the focused app**: Pay special attention to two categories — native apps (Notes, Mail, Safari address bar) and Electron/Web apps (Slack, Chrome, VS Code). If terms only appear in native apps but never in Electron/Web apps, §5.2 is the primary cause.
4. **Single-attempt test**: Deliberately perform one "dictate → stop dictating → wait 15 seconds → edit → wait another 15 seconds doing nothing" cycle, and check whether a `terms added` log entry appears. If this extended-interval single test works but normal consecutive usage does not, §5.1 is the primary cause.

---

## 7. Recommended Fixes (Pending Confirmation Before Implementation)

Ordered by impact and implementation cost:

### 7.1 Change the "Consecutive Dictation Cancels Immediately" Policy (Addresses §5.1) ★★★★

**Current behavior**: A new dictation immediately cancels the previous observation session.
**Proposed behavior**: When a new dictation arrives, **immediately finalize** the previous session instead of simply canceling it. Specifically:

- Replace "cancel" with "immediately truncate observation and run analysis": use the already-collected `state.latestObservedText` to call `runAutomaticVocabularyAnalysis` right away, even if the 8 s idle period has not elapsed;
- Alternatively, introduce a lightweight "quick settlement" path: as long as any change was observed during the session (`lastChangedAt != nil`), allow the analysis to proceed after interruption.

Implementation difficulty: **Low** (add a "finalize first, then schedule" step at the entry point of `scheduleAutomaticVocabularyObservation`). This covers the broadest set of user scenarios.

### 7.2 Relax the Minimum Length for English Candidate Terms (Addresses §5.4) ★★★

Lower the minimum length in `isValidLatinOrNumberToken` from 4 to 2 or 3, while keeping the LLM-side requirement of "minimum 4 characters / must contain a letter." Even if the diff stage admits a few more short tokens, the LLM will filter out the vast majority of noise.

Alternatively, take a more conservative approach: differentiate the length threshold between "pure-letter terms (minimum 3)" and "terms containing digits (minimum 4)."

### 7.3 Reduce Idle Settle Delay / Introduce Multi-Stage Triggering (Addresses §5.1 + §5.3) ★★★

The 8 s idle period is too long for practical use. Recommendations:

- Keep 8 s as the upper bound;
- When the observed `state.latestObservedText` differs from the baseline by a "sufficiently significant" amount (e.g., a new token of length ≥ N has appeared), attempt a **preliminary analysis** (validate only, do not persist) to reduce the chance of edits being interrupted by the next dictation.

Or, more simply: reduce the idle delay from 8 s to 3–4 s.

### 7.4 Improve AX Value Read Robustness (Addresses §5.2 / §5.3) ★★★

- Increase the `readInitialEditableSnapshot` retry count from 1 to 2–3;
- When `failureReason == "missing-ax-value"`, display a status message in the settings UI such as "Current app does not support automatic vocabulary," to help set user expectations;
- For the paste fallback path, increase `automaticVocabularyStartupDelay` from 600 ms to 900–1200 ms (or use a paste-path-specific delay).

### 7.5 Relax the LLM Decision Prompt (Addresses §5.7) ★★

- Remove the conservative instructions "Prefer precision over recall" and "If uncertain, return an empty list";
- Keep the mandatory rejection list, but provide clearer signals for **positive classification** (e.g., "prefer keeping any capitalization/spacing correction that spans two or more tokens").
- Optional: apply a "lenient mode" to LLM responses — treat the LLM-returned terms as nominations, but only persist those that also pass deterministic rules (e.g., match `acceptedTermRegex` and exist in `normalizedCandidateTerms`).

### 7.6 Observability (Addresses §5.8) ★★

- In Settings > Vocabulary tab, add a collapsible section "Last 10 Automatic Vocabulary Sessions" that lists each session's exit reason (e.g., `session aborted (focused-element-not-editable)` / `analysis skipped (edit too large, ratio=0.72)` / `terms added`), enabling users to self-diagnose issues;
- Prefix Console log entries for `[Auto Vocabulary]` with a session ID to facilitate cross-line correlation.

### 7.7 Edit Ratio Threshold (Addresses §5.6) ★

Raise `automaticVocabularyEditRatioLimit` from 0.6 to 0.8–1.0, or switch to "use an absolute character upper bound rather than a ratio for short insertions (< 20 characters)." Retain the "skip large rewrites entirely" safety net.

---

## 8. Recommended Implementation Order

1. **Add logging/telemetry first** (§7.6): without changing any semantics, expose end-to-end failure causes so that both users and developers can confirm the root issue.
2. **Combine §7.1 (highest impact) + §7.2 (least invasive)**: together, these two changes are expected to address 60%+ of the "automatic vocabulary does nothing" scenarios, with controlled risk.
3. **Address §7.3 / §7.4 / §7.5 as needed**, informed by the logging results from the previous step.

All of the above changes have corresponding existing unit tests that can be reused (`AutomaticVocabularyMonitorTests`, `WorkflowControllerAutomaticVocabularyTests`). When implementing §7.1, be sure to thoroughly cover the new path: "a new session interrupts an old session → the old session already has changes → it must finalize and persist."
