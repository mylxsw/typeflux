# Text insertion: behavior-first redesign

Date: 2026-09-05
Status: implemented locally; automated validation and packaged-app startup are recorded in TEXT_INSERTION_IMPLEMENTATION_2026-09-05.md. Cross-application interaction acceptance remains pending.

## Source of truth

The user's six behavior requirements supersede architectural recommendations in the earlier audit. Existing code is evidence about defects and migration work, not the specification for correct behavior.

The product should feel like entering text into an editor: generated text goes to the user's current insertion point, replacing the current selection when one exists. A persona action on explicitly selected text has a source selection whose identity matters. Internal delivery mechanisms should not become separate user-facing modes or compatibility switches.

## Required behavior

| User action or state | Required result |
|---|---|
| Start voice input while editing; stay in that field | Insert generated text at the active caret when output is ready. |
| Move to another app/window with an editable input while processing | Insert into that current input. Do not return to the initial app or reject the operation merely because the app changed. |
| Move to a destination with no insertable input | Show the existing insertion-failed dialog with the complete generated text and a copy button. |
| Place the caret in the middle of existing text | Insert there; preserve all text before and after the caret. |
| Select text and invoke ordinary voice input | Replace the active selection with generated text; preserve surrounding content. |
| Select text and invoke the persona shortcut | Present the persona picker; generate according to the chosen persona; replace the selected source text. |

For ordinary dictation, the active caret/selection at delivery time determines the edit. If the user moves to a new field during processing, an old selection is not authority to overwrite the previous field. Initial selected text may still be generation context when the feature requires it, but generation context does not own the dictation destination.

The two shortcuts represent different explicit user actions. Merely finding selected text during ordinary dictation must not unexpectedly open the persona picker.

Confirmed persona behavior: choosing a persona directly rewrites the existing selected text. There is no additional recording or transcription step. Preserve the existing persona selection and rewrite-generation behavior; this redesign concerns its subsequent write-back and recovery through the shared delivery service.

## Principles

1. User intent chooses the edit; transport capabilities do not redefine it.
2. Ordinary dictation follows current external focus. Capture its destination as late as practical, immediately before delivery.
3. Selection-based persona generation retains the exact source selection. Typeflux's own picker must not accidentally become the destination or destroy that selection.
4. One result receives at most one potentially effective delivery attempt unless an earlier mechanism is known to have performed no write. Lack of confirmation is not permission to duplicate text.
5. Output is retained before delivery. A failure must never discard the generated result.
6. Insertion, selection replacement, and middle-of-text insertion use the same conceptual editor operation: replace the active range, whose length is zero for a caret.

## Two operation intents, one delivery service

### Ordinary dictation: current input

`shortcut → record → generate text → resolve current external input → replace current range → finish or show recovery`

Do not bind the result to a starting PID, window or selection. Resolve the current destination when generation is finished, then validate and deliver promptly. If focus changes again before delivery starts, re-resolve within a bounded preparation window; do not write using stale target information or keep chasing focus indefinitely.

The original app changing is normal behavior, not an insertion failure. A zero-length range is normal insertion, not missing-selection evidence.

### Persona action: selected source

`selection shortcut → retain exact selection and origin → choose persona → generate text → replace selected source → finish or show recovery`

Generation directly rewrites the selected source using the chosen persona, without recording. Retain raw selected text, range and sufficient editor identity separately from normalized generation input. Change this path only where needed to preserve the destination and deliver the rewritten result; do not redesign persona generation as part of the insertion work.

Distinguish focus changes caused by Typeflux's picker from the user's intentional navigation. Closing the picker should let the source editor accept the replacement without treating the picker as an external destination. The required baseline is successful source-selection replacement when the user remains in that editing context.

Intentional navigation away during a persona rewrite is not explicitly specified in the six requirements. Proposed default: preserve the output and show recovery if the original selection cannot be safely addressed; do not overwrite unrelated text. Keep this policy explicit, rather than inheriting it from legacy transaction checks.

## Small implementation boundary

Keep four responsibilities clear; these do not require four new subsystems or a large plugin framework:

| Responsibility | Owns | Does not own |
|---|---|---|
| Workflow | Recording, generation, operation intent, retained output, cancellation | AX roles and keyboard event details |
| Target resolution | Current external input for dictation; source selection for persona | Generating content or presenting dialogs |
| Text delivery | Native write or paste, exact range semantics, temporary clipboard ownership, delivery evidence | Persona rules and overall workflow UI |
| Result presentation | Completion or retained-result recovery | Retrying keyboard events implicitly |

A single asynchronous delivery API accepts generated text and one of the two operation intents. It returns an outcome with a reason and evidence level. Avoid separate persona and dictation paste implementations, mutable global last-method state, or settings whose meanings depend on which path happened to execute.

Use the simplest proven write mechanism for the target. AX can provide target/range information without being the only permissible writing mechanism. Missing AX readback does not by itself prove that an input is non-insertable. A copy response alone does not prove a destructive replacement is authorized either.

Do not make direct AX writing mandatory for all native editors or paste mandatory for every app before measuring actual behavior. Transport policy belongs inside delivery and should be shared by both intents.

## Completion and recovery

The visible happy path remains simple: generated text appears, then the processing indicator closes. Known delivery failure uses the existing dialog with the full output and copy button.

Internally, preserve three distinct delivery outcomes:

- Verified edit: finish without a failure popup. External AX setter acknowledgement alone is insufficient.
- Blocked before writing or known rejection: show the failure dialog and specific reason.
- Dispatched but unconfirmed: retain output and an explicit unverified status in history, without automatically opening a dialog. Stale or missing AX evidence does not establish failure. Do not claim verified insertion or dispatch another paste automatically.

The last state is an internal accuracy requirement, not an extra workflow the user must configure. It prevents the current two extremes: silently calling dispatch successful, and calling an already-applied edit a failure.

Observation must be bounded and must not stall the UI. Clipboard restoration must respect newer user clipboard changes and the ownership of in-flight delivery. These are implementation constraints; they should not add steps to normal input.

## What to discard from the previous plan

- Binding ordinary dictation to the starting editor.
- Treating an app/window change during dictation as a reason to reject insertion.
- Requiring a captured non-empty range for ordinary insertion or its normal active-selection replacement behavior.
- Exposing “capture succeeded but replacement is disabled” as the desired end-state for genuinely insertable fields. That is a compatibility gap to solve, not a product requirement.
- Preserving old AX/paste branches or strict/stubborn flags simply because they already exist.
- Building an extensive per-app adapter framework before a measured compatibility need exists.

Keep only necessary protections: do not overwrite unrelated content, do not repeat ambiguous writes, preserve results, preserve the user's clipboard, and respect cancellation.

## Implementation and acceptance order

1. Encode the six requirements as behavioral tests, including moving to a new editable field, moving to a non-editable destination, insertion in the middle, and selection replacement.
2. Build the shared delivery entry point with the two explicit targeting intents. Retain generation workflows; replace delivery internals in scoped steps.
3. Correct raw-selection preservation and any persona picker focus behavior needed for reliable write-back. Connect the existing direct-rewrite result to shared delivery without changing persona generation.
4. Add bounded delivery observation and recovery tests. Ensure cancellation and rapid consecutive sessions cannot lose output or cause duplicate edits.
5. Remove superseded routes and obsolete settings after their required behavior is covered. Keep general text-context extraction used by other features outside the cleanup scope.
6. Run signed-app acceptance tests across native text fields, browser textareas/contenteditable, and the user's failing apps. Include whitespace, newline and emoji selections, same-app window changes, app changes, clipboard changes and delayed targets.

Acceptance is based on visible text and surrounding-content preservation, not dispatch logs. Both shortcuts must produce the specified behavior without per-user compatibility tuning. Report any unsupported target explicitly rather than claiming universal coverage from unit tests. No source changes, commits or deployment have been performed for this revision.
