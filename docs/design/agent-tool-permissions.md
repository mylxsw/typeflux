# Agent tool permissions

The authorization table in `AskToolAuthorization.swift` is the source of truth for Agent settings and tool admission. Settings → Agent → Permissions edits each operation independently for Strict, Standard and YOLO. A setting is Allow, Ask or Deny; Reset Mode resets only the selected mode.

## Defaults

Standard permits reads and internal bookkeeping, and asks before writes, execution and unknown operations. Strict asks by default. YOLO permits classified operations. Embedded browser read, snapshot and screenshot default to Allow in every mode. Unknown operations default to Ask in every mode, including tools claiming to be read-only. The user can explicitly override each entry.

Directory grants, hidden notebook tags, private tabs, site denials, disabled capabilities, system permissions, observation freshness and recovery restrictions remain execution prerequisites. Allow cannot grant any of them. Site settings only allow or deny access; they no longer provide a second approval policy.

## Adding tools

- Add a built-in operation to `AskToolAuthorization.builtins` with its real effect. Do not add a separate mode switch or approval exception in an executor.
- Offer tools through `AskLocalTools.definitions` or the engine's authenticated cloud-tool inventory. Both register definitions for the settings table. New action enum values and unknown tools appear automatically, defaulting to Ask until classified or explicitly configured.
- MCP discovery also publishes the inventory before a conversation uses the tools. External names, schemas and read-only annotations do not establish read authority. User overrides are bound to the server configuration and tool definition fingerprint; changes invalidate those overrides.
- For tools without an action enum, the table controls the whole tool. If one tool mixes reads and writes, expose explicit actions instead of hiding writes in free-form parameters.
- Never run a subprocess in a read handler. Workflow path lookup and interpreter version execution are separate tools for this reason.
- Add localized labels and tests for the new operation. Raw names remain usable as a fallback for dynamically discovered tools.

## Dispatch and revocation

Deny is checked before preparation; it returns a denied receipt without presenting an approval button. Allow still prepares and validates the live execution binding. Ask waits for a single-use grant. Dispatch checks the permission revision again, and operation callbacks recheck it while executing. A changed table cancels old pending approvals. Distributed notifications and preference refresh propagate changes to feature processes. Already completed effects cannot be undone by revocation.

Engine-owned recovery completion also passes through client authorization when client approval is enabled. Its evidence and recovery-state validation remain mandatory.

## UI

The page uses TFPaneHeader, TFSegmentedControl, TFSearchField, TFCard, TFDisclosureRow, TFFormRow and TFPopUpButton. Tool groups contain action rows; there are no explanatory subtitles on each row. Technical operation IDs are available on hover. The table supports search and per-mode reset.

The standalone workflow editor assistant uses the same Standard-mode table. Its confirmation is shown with shared form/card/button components before a draft is changed or a subprocess runs. An approved test does not open a second editor-specific approval. Manual user-initiated test runs retain their existing workflow safeguards.

## Validation (2026-10-25)

- The focused scope selected 278 test methods covering policy defaults, persistence, deny/ask/allow dispatch, pending revocation, browser and file prerequisites, MCP discovery, notebook access, workflow execution, recovery, and settings rendering.
- The first completed pass took 333.33 seconds including build and discovery. It found a permission-revision serialization bug and outdated policy/fixture assertions. After those fixes, a reduced retry selected 101 methods and passed in 130.34 seconds including build and discovery. Previously passing unrelated suites were not repeated.
- Changed executable line coverage is 353/395 (89.37%), calculated from the initial and retry profiles against the final binary. The calculation includes new production files and this task's added/modified lines, excluding unrelated work already present in DIContainer and AskConversationModel. Changed function profiles from the old binary are not a substitute for the retry's current-function coverage.
- Settings renders were inspected at 460 and 760 points, in light/dark appearances, and in the complete Agent settings shell. The view reuses the shared form controls and adapts to narrow width.
- An earlier ordinary build succeeded in 94.68 seconds. Two preparatory coverage builds were stopped before executing tests (279.88 and 58.82 seconds) while implementation was still being completed. These are separate from the completed validation times above.
- No full test suite, signed app relaunch, or production deployment was performed.
