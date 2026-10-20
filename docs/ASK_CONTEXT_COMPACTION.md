# Private conversation context compaction

`AskSemanticCompaction` plans incremental continuation summaries against the
selected model's actual context window. `AskLocalEngine` retains original history,
the latest user request and complete recent tool groups. Summaries are persistent
`summary`/`summary_through` checkpoints, never replacements for execution receipts.

The shared auxiliary-model choice retains `ask.title.model` for compatibility.
Titles and summaries use that choice; automatic follows the conversation model
locally. Cloud conversations use the server's existing feature/model routes.
No additional endpoint or credential fields are introduced.

At approximately 65% active input, the conversation window prepares a summary
through an injected helper runner while allowing the answer to continue. At 80%,
or after explicit context rejection, the engine waits at a safe step boundary.
Without a background runner, the same semantic operation uses the existing durable
inference bridge. Token-sized recent history and a concise summary aim for roughly
30% total occupancy, with no forced deletion of protected state.

Every preparation binds to a deterministic hash of its source prefix and previous
summary. New tail messages stay intact; modified source invalidates the result.
Idle completed checkpoints persist across restart. Cancellation/deletion cancels
local helper tasks. Provider usage is recorded independently from visible answers,
including late reports bound to their original budget root. Private summaries
never implicitly choose a cloud provider.

Failed helper summaries retry with the conversation model, then fall back to the
existing bounded emergency projection. Invalid/truncated summaries cannot become
checkpoints. Explicit context rejection returns to the engine for bounded semantic
recovery, rather than hiding repeated provider calls inside one invocation.
`read_conversation_history` retrieves original text in bounded Unicode pages;
binary image payloads stay in their original store.

Thresholds and retention targets are initial policy values. Semantic retention
quality and latency require representative model evaluations in addition to the
state-machine, transport, cancellation and accounting regression suites.

## Verification on 2026-10-20

Coverage runs include build, discovery and execution time. They replace plain
runs for the same scope; only failures or newly affected behavior were retried.

| Client validation | Total command wall time | Result |
| --- | ---: | --- |
| Initial scoped coverage build/discovery | 223.70 s | No tests executed: one suite name did not match discovery; corrected before execution |
| Corrected conversation, usage, recovery, budget, title and transport scopes | 42.32 s | Two XCTest methods failed; later targeted runs passed |
| The two failed XCTest methods | 88.54 s | Passed |
| Semantic compaction, auxiliary transport and affected callers | 118.08 s | 32 XCTest methods and 26 Swift Testing tests passed |
| Permission modes and semantic compaction | 115.92 s | 9 XCTest methods and 12 Swift Testing tests passed |
| History retrieval after exhausting web quota | 87.15 s | Passed |
| Integration after retaining the remote settings/localization update | 106.42 s | Localization, title, semantic compaction, permission and local-mode UI scopes passed |

The two newly added helper source files reached 92.4% combined line coverage in
the affected-caller run. This is scoped coverage, not application-wide coverage.
The native permission matrix also verifies that original-history retrieval is
read-only in standard mode and still requires approval in strict mode. Original
history retrieval does not consume the separate web-request quota.
