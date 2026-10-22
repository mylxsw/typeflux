# Feature process isolation

## Production boundary

The application launches its full signed executable with a private inherited
socket and a feature role. This is the normal application startup path, not an
opt-in viewer. Chat uses the existing conversation controller, composer,
attachments, approval sheets, tool execution, cancellation and transcript views.

The host owns the menu, canonical Ask API graph, conversation cache, account
refresh, sync and updater. Independent processes own chat, launcher, clipboard,
screenshot/recording, settings, voice input, ring, notes, word book, system monitor,
help and translation. Shortcut event taps run in another independent process.
A blocked AppKit main thread therefore cannot block shortcut delivery or another
feature's AppKit run loop. A shared operation may still wait for the feature
which owns that operation; isolation does not manufacture a successful result.

`FeatureSupervisor` is an actor independent of the host's main thread. Each child
has its own `FeatureRPC` connection, writer queue and request budget. Shortcut
routing to feature windows and the cached bootstrap account snapshot do not wait
for the menu process's main thread. Voice gestures follow the focused composer
or the current recording owner; microphone admission is exclusive.

## Storage and execution ownership

Presentation processes use typed `FeatureAskAPI` and `FeatureAskCache` adapters.
Only the host opens canonical engine state, account journals and conversation
cache. Existing nonblocking directory leases remain enabled. A session generation
fences requests and replies across account changes. Profile, token and subscription
refreshes return to the host; children do not own refresh tokens or refresh timers.
The host's resolved data, workspace and cache directories are inherited exactly,
including migration fallback locations.

Chat owns the persistent command-job store. Launcher quick ask remains an inline,
tool-free operation, as before; its ongoing inference retains one driver when its
conversation is displayed in Chat. The supervisor rejects a second execution
driver for the same active conversation. Durable execution claims and receipts
remain authoritative. Cancellation is forwarded to the original quick-ask driver.
No timeout, crash or lost acknowledgement automatically replays a write or starts
a second provider request.

Draft handoff stages non-temporary drafts before sending the complete input,
attachments, references, model and permission settings. The destination deduplicates
handoff identities and acknowledges acceptance. Only an unchanged source is then
cleared. A lost acknowledgement leaves the source intact; an explicit retry uses
the same identity. Temporary input remains memory-only. Unsaved Chat drafts flush
before ordinary application shutdown.

Notes, word-book and history notifications cross the supervisor without echoing.
Preference changes refresh model registries and the relevant local notifications.
Translation handoff carries presentation snapshots and coalesced stream updates;
its original provider call stays owned until completion or explicit cancellation.
A screenshot that cannot reach its destination is saved and its location is shown.

## Failure and lifetime policy

RPCs have finite deadlines, at most 32 pending and 32 executing requests per
connection, bounded payloads, bounded writer queues and no automatic retry.
Cancellation skips queued requests that have not reached the writer. Failure of
one channel closes only that channel. There is no public socket listener, port,
credential file or shell-based launch command.

Children are application-owned managed processes, without an arbitrary 24-hour
expiry. Normal shutdown first flushes drafts and stops owned work, then closes
channels and reaps process groups. Children monitor parent death. Exited windows
may be launched again on the next explicit request, limited to three launches
per role per minute. The shortcut process is restarted within that same budget.
Hung windows are not automatically killed: doing so could discard in-memory input
or obscure an already dispatched external effect. Other processes remain available.

The earlier read-only `TypefluxChatWindowHelper` experiment is not the production
window. It does not receive production presentations. The active implementation
is under `App/Isolation` and reuses the complete application executable.

## Validation

`FeatureRPCTests` exercises bidirectional concurrency, a stalled request, deadlines,
cancellation, malformed channels and request budgets. `FeatureAskAdapterTests`
uses the typed production channel for chat operations and canonical cache claims,
drafts and receipts. Handoff and translation suites cover acknowledgement loss,
source edits, account changes, temporary input, late updates and no repeated
provider calls. Existing lifecycle, approval, voice, screenshot, clipboard and
account suites cover the affected callers.

`FeatureProcessFreezeTests` is an explicit native integration test. It creates a
separately identified, ad-hoc-signed fixture bundle and private data directories;
it never opens production databases or captures the real clipboard/screen. It
starts the actual feature entry points and verifies distinct process identities.
It then deliberately blocks all twelve feature UI threads in turn and exercises
the other primary native windows through the shortcut process while each target
remains blocked. It also freezes and replaces the shortcut process, blocks the
host main thread, checks shared notes, sends a chat with an attachment, verifies
deduplication, cancels owned command processes and verifies all children exit. Injection
is compiled only in debug builds and additionally requires the fixture identity.
Run it with `TYPEFLUX_FEATURE_FREEZE_TEST=1` in the focused coverage scope.

### Validation record (2026-10-22)

The production path is enabled at ordinary startup. The focused regression scope
covers RPC and cache adapters, draft/translation handoffs, account fencing,
command ownership, voice cancellation, shortcuts, screenshots, clipboard,
recording sessions, storage and service recovery. The broad pass ran 336 XCTest
and 156 Swift Testing tests. All XCTest tests passed; one native-chat test and
four recording tests required the repairs and focused retries below.

- Native fault injection passed for all thirteen child roles and a blocked host
  main thread. Independent windows opened in 0.13–0.62 seconds in the final
  handoff/native retry while the other feature stayed blocked for four seconds.
- Draft acceptance now reports whether submission was actually admitted. A
  rejected submission retains the source and supports explicit retry; a lost
  acknowledgement does not submit twice. Six handoff/routing tests passed.
- Recording diagnosis found 62 AppKit animation threads occupying the dispatch
  pool. Capture/editor window transitions now skip native window animations.
  All ten recording session tests and six real-codec synthetic-media tests
  passed, including sixteen consecutive encoder create/finish/release cycles.
- No test used a live paid AI provider, real screen capture, microphone or camera.
  The native fixture uses the actual app controllers with isolated storage and
  synthetic capture/provider inputs. It is not a substitute for signed release
  distribution, notarization or live-provider testing.

Changed executable Swift-line coverage is **75.82% (1,656 / 2,184)**, below the
repository's 90% target. This is changed-code coverage, not project-wide coverage.
The report uses current source mappings, the broad-pass profiles for unchanged
files, the handoff/native retry profiles for subsequently edited routing and
submission files, and the final recording profiles for recording files. Each
profile group merged without warnings; incompatible historical runs were not
combined. Uncovered UI actions and error branches remain a coverage limitation.

Command wall times include compilation and discovery: broad regression 254.31s;
final recording retry 61.75s (37.44s build/discovery, 24.30s execution). Earlier
failed attempts and diagnostic runs are retained in the task's validation logs;
passing retries do not erase those failures. Release compilation is verified
separately before main-branch delivery.
