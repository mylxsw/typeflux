# R02 shared run budget and context contract

R02 is opt-in and builds on R01 at API `07a4fe2be9e6646228c73a98f31f7a92d9f6c0c1`
and Swift `e314b9933a83ed1b9faaf1f874bfa9183d21c2f5`. Initial PR bases are the
R01 dependency branches, not main. Deploy the compatible API before the client;
merge R01 first, then rebase and repeat combined checks. No production enablement
or automatic merge is part of this delivery.

## Configuration and rollback

- API: apply migration `00040_add_ask_budgets.sql`, then explicitly opt in with
  `ASK_RUN_BUDGET_ENABLED=true`. Its default is false.
- Client: `ask.budgetEnabled` defaults to false. Restart the app after changing it.
- Fresh runs receive 500,000 estimated tokens, 100 credits of estimated platform
  cost, 16 web requests, 4 research children, 128 operations and a 10-minute wall
  deadline. Engine configuration can inject stricter limits for acceptance tests.
- Explicit new user turns/regeneration receive a new budget. Retrying an interrupted
  run inherits its root budget, reservations and original deadline. Steering never
  grants more resources. Legacy step/tool ceilings remain in place.
- Research is unavailable without the shared budget. Turning off the feature does
  not erase journals or remove limits from already pinned runs. Do not roll back
  by dropping the table or deleting local journals. Existing production safety
  gates (including local web_fetch, worker recovery and memory provenance) remain
  unchanged. This feature does not enable desktop or browser write permissions.

## Persistent state and R03 integration

`BudgetController` / `AskBudgetController` implement the same version-1 state.
`docs/harness/fixtures/r02-budget-v1.json` is identical in both repositories and
is decoded by both test suites. R03 must reuse this state and store instead of
adding a second counter.

- Scope is authenticated owner + conversation + root run on the API. Local storage
  lives in the existing local-engine directory, in a separate `Budgets` journal.
- Reserve checks all occupied resources atomically. API CAS uses its own revision
  in `ask_budgets`; local writes use an advisory file lock and atomic replacement.
  Neither is tied to the conversation content revision.
- `reserved` means no dispatch yet. `Start` commits `pending` before external
  work or a device request is exposed. Starting the same operation twice fails.
- Only `reserved` can transition to `released`. A timeout, disconnect, cancellation,
  provider error, incomplete stream, missing receipt or process crash cannot prove
  absence of execution. Such reservations stay occupied after restart.
- Settlement is monotonic and idempotent. Observed usage above the reservation is
  still recorded and prevents subsequent admissions. A complete provider receipt
  may replace estimated token/cost occupancy. Incomplete, estimated and client
  reports cannot refund reserves. Token and cost finality are separate.
- Billing callbacks capture immutable identity and persist independently of content
  CAS. Reads reconcile pending reservations with the existing usage ledger; they
  never issue another bill. Cancelled custom inference accepts late metering for
  a known reservation without reviving its answer. There is no automatic replay.
- Web and child counts are dispatch quotas, spent once execution starts regardless
  of result. Plan updates spend operations but no web request. Parent tools and
  concurrent research loops share one controller. Go counts additional HTTP
  requests/redirects at transport admission; budgeted local search refuses redirects.
  Transport-internal retries before a request is written remain the HTTP library's
  responsibility. Budgeted custom-model adapters disable reasoning fallback retries.

## Context and provider output

The planners account for message content, tool arguments/results, schemas, existing
summaries, image reserves, output reserve and framing headroom before requests.
Catalog windows/output limits are pinned on cloud runs; registered custom-model
limits are resolved on the device before dispatch. Unknown models use an estimated
32,768-token window and a 4,096-token output ceiling. Output is additionally bounded
to one quarter of the window. OpenAI, Anthropic and Gemini receive the output cap;
Anthropic thinking consumes the same reserve instead of increasing it.

Budgeted planning no longer uses message count. It first shortens successful tool
output with explicit incomplete-evidence markers, then omits images with markers.
It preserves system/user constraints, refusals/errors, tool arguments and the
complete sequence of call/result envelopes. If protected content or schemas alone
cannot fit, it stops before inference and asks the user to reduce context. It does
not silently drop constraints, split tool rounds or send an oversized summarizer
request. Durable history and memory provenance remain intact. Existing summaries
consume budget; R02 does not add a paid summarizer call. Source memory is revalidated
before projection, and R01 owner isolation, expiry, tombstones and purge remain
in force.

Tokenization and vision expansion are conservative estimates, not a provider
contract. Unknown/custom models can have a smaller actual window. Actual platform
charges and client-reported usage are displayed separately from occupied reserves;
external-provider cost is not verified or guaranteed to stay below an exact price.
Only scheduler-controlled web/child/operation admissions and deadlines are hard
quotas. Existing material is retained and surfaced on a budget stop without another
paid model call or new action.

## Diagnostics and compatibility

Optional run fields expose budget occupancy, reported usage, pending count,
deadline, metering provenance and stop reason. Correlation events carry run, step,
call and operation IDs, kind and state. They contain no prompt, tool arguments,
credential, response body or URL. Budget versions can update after cancellation
without changing or reviving conversation content; API SSE and Swift reconciliation
honor that independent version.

Old snapshots decode without budget fields. API/client request metadata for custom
inference is only emitted on opt-in runs and is removed before provider requests.
Do not enable the API flag for old clients before combined acceptance. R01 memory
budget metadata still reports its existing 1,000 + 4 x 1,000 scalar bounds; it grants
no resources to this controller. API migration 40 was allocated after checking main
and the single in-flight R01 PR (which has no migration).
