# Device-owned Ask execution

Authenticated desktop conversations use `AskDeviceAPI` and an account-scoped
`AskLocalEngine`. A run's model/tool loop, approvals, cancellation, budgets and
execution receipts remain on the Mac. The existing execution journal still
decides whether an operation may run or needs inspection; a history snapshot
never grants execution authority.

## Cloud services

- `POST /api/v1/ask/device/completions`: one model invocation through the Ask
  catalog, entitlement check and existing billing journal. It creates no server
  conversation or task. A transport failure is not automatically retried against
  a second replica because the first invocation may already have been billed.
- `GET/POST /api/v1/ask/device/tools`: the configured public web tools. The
  server's existing network and SSRF restrictions still apply. Local execution
  retains tool approval and result journaling.
- `GET /api/v1/ask/device/history` and `GET/PUT .../history/:id`: observation-only
  history, stored in PostgreSQL separately from server-executed conversations.
  Model credentials, pinned memory and pending execution payloads are excluded.

API replicas share the database and do not need request affinity. Authentication,
credit accounting and synchronization still have persistent records; this is
not a claim that the whole system stores no state.

## Persistence and synchronization

Account-owned execution snapshots live under
`~/.typeflux/data/AskDevice/<account>/conversations`. The separate `sync.json`
journal stores pending revisions, acknowledgments, ownership migration intents
and deletion tombstones. It does not duplicate attachment bodies or store JWTs.

Execution commits before a history upload is scheduled. Sync retries run in the
background with backoff; one failing conversation does not block others. After
a restart, local snapshots reconstruct any missing outbox entries. A slow upload
cannot remove a newer pending revision. Account changes stop retries under the
old credentials; token rotation may refresh credentials only for the same account.

Temporary and explicitly private conversations are not uploaded. A pending-sync
hint in history does not change task status. History uploads are limited to 32 MiB;
an oversized conversation stays on the Mac with synchronization pending. Cloud
inference and Cloud web tools still require connectivity even though the task
state is local. Only custom/local providers can continue without those services.

The replica fixes a writer device on first adoption. Another Mac can read it but
cannot use it to resume tools or silently take over execution. Explicit cross-
device handoff is not implemented. Provider-reported Cloud token counts are
shown without inventing an authoritative per-conversation charge; the account
billing journal remains authoritative.

## Legacy migration and rollout

Deploy API migration `00083` and the new endpoints before distributing the desktop
client. Custom-model tasks can execute while the sync service is unreachable;
Cloud model calls require the new invocation endpoint and never fall back to
server orchestration.

Existing active server runs keep their original route. A new message, retry or
regeneration of a terminal legacy conversation first imports its history and
confirms device ownership with the server. The database rejects adoption if the
legacy history changed, remains active or has an uncertain outcome. A lost
adoption acknowledgment retains the local intent and is retried before any new
model/tool dispatch. Server-owned budget authority is not imported.

Database triggers prevent old API binaries from starting another server run for
an adopted identity. Privacy-memory erasure remains allowed. A synchronized
deletion removes the legacy history copy too; the tombstone prevents delayed
uploads or old clients from resurrecting it. Existing independent billing
retention rules still apply.

Keep migration `00083` when rolling API binaries back. Dropping its ownership
fences while device clients are active would permit conflicting writers.

## Local validation (2026-10-22)

The selected checks passed, with 178 distinct desktop test names across the
initial pass and scoped retries. Desktop scopes covered the device API, model
and history HTTP transports, local engine and reentrancy, token accounting,
application composition, model-client injection, recovery/approval safety,
workflow assistant, stream parsing, history refresh/rename and localization.
The terminal suite was checked after adding the required shared UI-state trait.

| Invocation | Total wall time | Outcome |
| --- | ---: | --- |
| Desktop compile/discovery preflight | 27.72 s | Immutable credential configuration required a copied configuration; repaired. |
| Desktop compile/discovery retry | 104.63 s | A throwing async test assertion required a separate awaited value; repaired. |
| Initial focused desktop coverage | 259.28 s | 50 XCTest checks and application composition passed; the new sync worker trapped on overlapping dictionary access. |
| Scoped desktop continuation | 63.76 s | Sync worker repair verified; one stale default-client assertion and one pre-existing missing UI-state trait remained. |
| Final focused desktop coverage | 89.39 s | All 49 checks in the six remaining/extended suites passed. |
| API/database/route validation | 3 s | Passed, including a real isolated PostgreSQL cluster and two independent connection pools. |
| Additional HTTP/catalog error-path coverage | 5 s | Passed. |
| Global HTTP body-limit integration | 2 s | Passed, including unknown-length bodies at and above each new limit. |

The sync trap was caused by reading and mutating `accounts` in one assignment;
the acknowledged revision is now computed before mutating the dictionary. The
slow-upload regression verifies that acknowledging an older snapshot cannot
drop a newer pending result.

Coverage for the three new desktop execution/sync modules is 511/534 executable
lines (95.69%). The three new Go model/history/handler modules cover 133/141
statements (94.3%). These are new-module measurements, not a claim of full-project
coverage. The final filtered desktop report has 2.44% whole-codebase line coverage
because unrelated features were not exercised.

PostgreSQL checks apply migration 83 both to a minimal legacy schema and on top
of the existing durable execution, route and settlement migrations. They verify
account isolation, monotonic revisions, writer ownership, migration rejection
for active/uncertain runs, old-writer fencing, privacy erasure and deletion
tombstones. HTTP catalog/credit checks use mock providers; no real provider
requests or charges were made.

The installed development app, production API deployment and live multi-server
traffic were not changed or verified by this validation. Interactive rendering
and the originally reported reasoning-expansion hang were outside this change.
