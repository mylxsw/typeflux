# GUL-458: per-run turn adapter integration

The application runtime remains a host facade. A separate pure, owned-data turn adapter selects model, tool, finish or suspend decisions. The host retains approved model configuration, context planning, tool approvals, budget journals, receipts and atomic conversation transitions. Production enables only `typeflux.default`.

Private version-1 state is pinned to run/binding/sequence and stripped from public snapshots. Unknown state stays readable but cannot execute. Alternate activation requires trusted enabled registration, compatible bounded peer declarations and an exclusive state-compatible cohort; headers alone grant no authority. Summary intent uses the already approved model without tools. Auxiliary title/context services remain host-owned.

Self-review covered end-to-end completion/reload, account/device/run identity, stale revision and lease checks around async work, cancellation, unknown/invalid decisions, approval and budget boundaries, duplicate/archived receipts, raw JSON preservation, atomic state writes, bounded admission and resource ownership. No credentials or privileged host objects cross the adapter boundary.

## Local evidence

Portable changed-line coverage uses only added/modified instrumented product lines; tests, declarations, comments and noninstrumented lines are reported separately. Raw commands, timings, profiles, normalized line counters, zero-context diffs, prior failures and reproduction scripts are attached to the GUL-458 result comment. No global unit/UI suite or external CI watch was run.

- Affected coverage command: `make coverage SUITE="AskAgentTurnTests AskAgentBindingTests AskRunRouteTests AskApplicationAPITests AskLocalEngineTests AskLocalEngineReentrancyTests AskLocalBudgetTests AskAgentBindingInteractionTests AskQuickAskTests AskAPIClientTests"`.
- 120 selected test methods passed, including real application fake model receipt → approval → host tool → outcome → finish/reload, default spy, Quick Ask and cancellation/account races.
- Changed executable lines: 314/322 = **97.52%**.
- New source/test SwiftLint: zero errors; surrounding changed files retain existing identifier, actor length and forced-try violations. Whole-file lint is not claimed green.
- Initial coverage build was invalidated by an edit; the first executed scope found nondeterministic JSON header ordering. It was fixed, then affected tests and smaller adapter/HTTP refinements passed. Final evidence uses one final binary/profile rather than merging incompatible constructor counters.
- The exclusive directory owner holds an OS lock and one engine writer lease; the descriptor closes on exec and deinit. Production directory aliases resolve before admission. Alternate local activation remains unavailable in production composition.
