# Local Ask prompt host port

`AskLocalEngine` owns an injected `any AskPromptBuilding`, defaulting to
`DefaultAskPromptBuilder()`. Its two methods are synchronous pure transformations
in the caller's actor. The Sendable inputs contain conversation snapshots and
explicit policy/environment values. They never contain an engine or local record;
untyped dictionaries remain in the actor that requested them.

`AskConversationPromptInput` includes tools, local date, time zone, locale and the
typed-content flag. `AskSummaryPromptInput` includes the requested prefix, model,
window and output cap. Summary output retains `typeflux_summary_through`, the
actual prefix that fits, until the existing queue/preparation owner consumes it.

## Production consumers

- `step` builds the answer payload after the existing memory sanitization and
  image preparation/revision checks, then passes it to the existing queue/planner.
- Foreground semantic compaction selects its boundary from the injected main
  payload and calls the injected summary method after resolving host limits.
- Background semantic compaction uses one prepared injected main payload for
  both the hard threshold and boundary, and the injected summary method for the
  helper request. Existing budget reservation, persistence, task ownership,
  cancellation and checkpoint activation remain at their prior boundaries.
- `AskSemanticCompaction.boundary(_:payload:limits:)` receives the prepared
  payload; it never constructs a hidden default prompt.

`AskLocalPrompt.payload`, `summaryPayload`, and the record-based compaction
overload remain compatibility wrappers for tests and pure legacy callers.
An audit leaves no production engine calls to those default payload wrappers.
Both production application factories inherit the new default parameter while
continuing to compose one local engine with their existing API/registry route.

The default preserves this platform's historical wording, memory envelope,
message/tool order, typed/media projection, original-history references, pinned
latest user, summary cut, model and reasoning fields. Swift and Go have separate
baseline fixtures because their prior payloads are not identical.

Title generation and research prompts retain their owners. Other host ports,
alternate runtimes, per-run dispatch, peer negotiation and prompt optimization
remain outside this increment.
