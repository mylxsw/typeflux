Cached cloud approvals now use the same live transport authorization as ordinary
delivery. The helper refreshes/reconciles the snapshot and checks account, operation
and recovery generations, original execution identity, pending arguments, effective
tool binding and an in-memory consumed grant. It never imports authority from the
journal. An already acknowledged call reconciles without another execution intent,
including an explicitly tagged result from a replaced run. Completed receipts and
original-run inference usage remain independently retransmittable.

Recovery observation uses a host-owned pure action allowlist. Offered action enums
are restricted to the same list; dispatch is authoritative. Site permission, approval
mode, MCP annotations and adapter claims cannot expand it. Existing approval risk
presentation remains unchanged. Refusal may send one non-execution receipt; it sends
zero approval intents and runs zero tools. User guidance avoids repeating the
not-executed message and explains how to start a new authorized request.

| Tool | Existing observation actions allowed during recovery |
| --- | --- |
| computer | screenshot, inspect, wait |
| browser | read, snapshot |
| web_browser | read, snapshot, screenshot, tabs, wait |
| files | list, read, search |
| project_files | list, read, review |
| project_terminal | status, output |
| Cloud | Existing web_search/web_fetch policy only |

The mapping was checked against AskComputerExecutor, AskBrowserExecutor,
AskEmbeddedBrowserTool, AskFileTools, AskLocalTools+Project and AskLocalTools+Terminal.
AskFileTools has no info action, so it is excluded. Navigation, tab mutation/selection,
handoff, click/fill, exports, commands, MCP, unknown tools/actions and malformed JSON
fail closed. Completed write receipts bypass this execution-only predicate.

Base: `50b8fdb69ce2a6b779500e25c2d4e9f37941ca90` (accepted integration on main).
Environment: Apple Swift 6.4, macOS 26.6.2 arm64. Final head is recorded in the PR and
GUL-437 delivery comment. Coverage uses the existing selected-suite runner; no full
test/UI suite, simultaneous SwiftPM runs or CI wait were used.

The initial scope selected 121 methods: recovery safety/interactions/journal,
permission modes, preparation failures, independent model selection, implementation
admission, default/fake local turn adapters, local engine/reentrancy and the focused
embedded-browser suite. All 50 XCTest methods passed. Swift Testing reported six
issues in two existing methods. The post-completion permission fixture now explicitly
resets the session; stop() was unchanged from the accepted base and only revokes an
admitted active operation. The restarted preparation fixture disables automatic
recovery before asserting that manual retransmission is available. No production
stop or permission-mode behavior changed to satisfy these fixtures.

A bounded correction scope repeated the amended safety suite, added the four frozen
wire/local recovery regressions, and retried the permission method. Its new late
inference test exposed a fixture timestamp precision mismatch, corrected with an
integral timestamp. The preparation method was initially missed because discovered
Swift Testing identifiers retain their backticks; a final exact method filter covers
it and the late inference method. Logs retain failed runs and exact scopes. An auxiliary
skip-build discovery without the native build-system flag looked in the wrong build
folder and failed without executing tests; the corrected discovery command is logged.

The API fixture refreshes held reads from current server state and preserves a newer
run when recording an original-run late inference request. Held-refresh tests assert
zero API result sends and an unacknowledged journal on account/generation/run/device/
call/argument/definition replacement. Other tests cover expired, missing, revoked and
restart-only approval, valid same-session grants, already acknowledged intents,
denials, completed write receipts, bounded automatic recovery and permissive-mode
refusal. Real WebKit site-permission tests keep the existing presentation risk and
also verify the independent recovery predicate.

Final result: 126 distinct test methods have passing evidence across 136 method
executions (121 initial, 13 correction, two exact retries). Total command wall time
was 663.40s + 84.78s + 100.43s = 848.61s, including dependency preparation, compilation,
discovery, runner startup, execution and the successful coverage report. The initial
build/discovery alone took 629.04s; later commands used incremental SwiftPM builds,
not cached passing results. All selected XCTest methods passed on the initial run.
The final two-method retry passed without changing production Swift source.

Changed executable-line coverage is 102/103, 99.03%. Focused lint of both recovery
extensions has no violations. The new test suite retains one nonblocking type-size
warning; AskToolPolicy retains pre-existing short-identifier/style violations. The
initial lint errors in the new fixture (short names and force try) were corrected.
Unrelated compiler warnings emitted while building the complete test source set are
retained in the raw build log; only the selected methods were executed.

Portable coverage is recomputed with the unchanged accepted GUL-457 script:

```sh
python3 docs/validation/gul-457/changed_coverage.py \
  docs/validation/gul-437/initial-scope.lcov.gz \
  docs/validation/gul-437/corrections-scope.lcov.gz \
  docs/validation/gul-437/method-retry-scope.lcov.gz \
  --base 50b8fdb69ce2a6b779500e25c2d4e9f37941ca90
```

Raw LLVM exports retain source provenance and combine maximum hits per line across
profiles. This measures added instrumented production lines, not project or branch
coverage. Tests, comments, declarations and localized string resources are excluded.
The late local authorization refusal throw remains uncovered; the initial and cached
approval recovery refusals are exercised. See changed-coverage.txt for the denominator.

Self-review checked account/run/device/call/argument identity, every suspension before
approval dispatch, live binding and grant revocation, generation replacement, receipt
versus intent separation, single journal acknowledgement, completed/old-run receipt
settlement, bounded recovery, intrinsic action mapping, offered/dispatch coherence,
malformed/MCP refusal, user copy, cancellation and unchanged ordinary browser policy.
No adapter interface, prompt, job framework or permission architecture was changed.
