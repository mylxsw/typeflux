# R01 memory lifecycle and integration contract

Memory sources are separate from conversation history and derived model text.
Deleting or correcting a source invalidates captured memory for that account.
This conservatively invalidates the whole snapshot, including legacy snapshots
without source IDs. It does not selectively erase summaries, messages, receipts,
or answers. A request already submitted to a model cannot be withdrawn.

## Ownership, migration, and retention

- Notes and Soul belong to the authenticated source owner (or `local` while signed
  out). That owner is independent of the local conversation cache partition.
- Recent is device-local **and** account-partitioned, then filtered by application
  or browser-page scope. Legacy unattributed Recent entries migrate to `local`;
  signing in never adopts them. Old JSON remains readable.
- Recent expires after 24 hours. Soul candidates expire after four hours; the
  consolidated summary stays until deleted. Explicit notes default to no expiry;
  correction supports preserving retention, seven days, thirty days, or no expiry.
  Expired notes are excluded even if disk cleanup fails; successful cleanup retains
  an empty tombstone. Recent cleanup happens on subsequent writes.
- Source metadata carries ID, source, owner, scope, version, creation/update dates,
  optional expiry and optional supersedes ID. Corrections create a new ID and
  increment version, scrub the retired source text, and retain its tombstone.
  Stale-version edits fail and remain retryable in settings.
- Source deletion commits to disk before success is exposed. Persistent deletion
  epochs reject earlier AX observations and Soul batches. Source tombstones recover
  snapshot invalidation after a crash between source commit and notification.

## Injection and compatibility

`AskMemory` keeps `global` and `app` and adds `owner`, `captured_at`, `expiry`, and
optional `sources` and `budget`. Budget fields report global/application scalar counts
and the fixed global/excerpt/count limits; they grant no additional budget. The opening message pins the snapshot. Global injection is
limited to 1,000 Unicode scalars; application injection to four excerpts of 1,000
scalars each. Explicit notes/corrections get the global budget before Soul.
Metadata reports only sources included within that budget. The complete snapshot
expires at its earliest included source expiry; it is never refilled silently.
Structured scope filtering and case-insensitive text search are used; no vector
index or new dependency is introduced.

The Go API accepts these additive fields, validates provenance bounds and account
ownership, and preserves them in JSONB. Deploy the API PR before the client PR.
`docs/harness/fixtures/r01-memory-v1.json` is identical in both repositories and is
read by their tests. No schema migration number is needed.

The opt-in UserDefaults key `ask.memoryProvenanceEnabled` defaults to false. It
controls full `sources` emission and the correction/retention editor and tool
action. Enable only after combined acceptance, restarting the app so the tool
store uses the same setting. Core account isolation, expiry, persistence, and
invalidation fixes are always active. Turning this key off retains corrections,
metadata, and tombstones. Do not delete these files as a rollback procedure.

`memoryOff` still controls injection only. It does not authorize memory writes;
`remember`, `forget`, and enabled `correct` still use P02 write approval. Correction
is never eligible for reusable approval. Disabling automatic collection does not
hide explicit notes.

## Concurrency and purge

Use `purgeMemory(owner:token:)` for owner-scoped local and authenticated cloud
cleanup; the legacy overload remains compatible. Owner-scoped durable cutoffs suppress stale draft/cache/fetch snapshots on submit,
retry, reopen, and before custom inference. Pending cloud purge is persisted per
owner and only that owner's response can acknowledge its deletion epoch. Purge
failure stays pending for the next launch/refresh; history remains intact.

The local engine and API remove generated `<user_memory>` system messages from
pending inference payloads when the source snapshot is invalid. They keep all
history and other payload fields. Local tool completion continues to merge its
delta onto the latest record (P03). PostgreSQL purge advances both CAS revisions
and stores `memory_purged`, preventing stale saves from restoring the snapshot.
The memory-backed evaluation store follows the same contract.

Cloud purge clears copies; it does not synchronize source stores or delete
history. Other devices retain their own source stores until separately changed.
The new client protects its in-flight copies; old clients do not gain the new
local invalidation checks simply because the API was upgraded.

## R02 handoff

Use `AskMemory.usable(owner:at:invalidations:)` immediately before injection.
Treat `sources` as optional provenance, never authority. Preserve the existing
1,000 + 4 x 1,000 scalar budgets and explicit-note priority when adding context
budgets. Do not conflate source owner with the `local` cache owner. Keep P03
latest-record merging and P04 atomic write-before-publish semantics. API/client
PRs may be reviewed independently but are not independent acceptance of GUL-180.
