# Local validation results

Swift base `5e31755bf9801d3ca3270180773bad3ffd37d0a1`; API base `fd445dcbb587acc7ec187db58f02eda102c45499`. Final submitted commits are recorded on the PRs and final issue comment. `source-hashes.json` pins the precise tested production/test files independently of commit metadata.

- Swift: **184 methods passed** (101 XCTest and 83 Swift Testing methods in nine Swift Testing suites; parameter variants are included beneath their methods in the log), zero failures/skips. The new queue journey exercised all five variants. Corrected coverage command took **127.948 s** including incremental compilation, discovery, execution, report and HTML export; the runner portion reported 114.24 s. This was an incremental rebuild, not cached passing evidence.
- The first Swift attempt took **488.789 s**, built successfully (469.20 s build) and then rejected an incorrect suite name before running any tests. Corrected `AskRecoveryNoticeTests` to the actual `AskRecoveryNoticePresentationTests`; the original log is retained as `swift-preparation.log`. There was one instrumented test execution, no duplicate plain pass. Existing Swift deprecation/concurrency warnings remain visible in the raw build log.
- API: **51 selected Ask top-level tests plus two HTTP tests ultimately passed** under `-race`, zero skips. PostgreSQL 16 was ready on **127.0.0.1:32770**. Initial Ask scope 175.169 s; failed-scope retry 89.988 s; last worker-method retry 28.087 s; HTTP 5.427 s. The required owner-regression preflight passed in 15.797 s. API README records the fixture deadline and provisional-metering assertion corrections. No baseline failure is omitted.
- `git diff --check` passed in both repositories. The 19 selected decision-copy keys exist in all five localization resources and have compatible placeholders. No production/UI/resource files changed.

## Measured production paths

These are focused source-file line counters, not changed-code, branch, repository-wide or real-provider coverage. No changed production executable lines exist in this increment. The >80% changed-production requirement therefore has no denominator; no artificial 100% is claimed.

| Swift path | Covered / executable |
| --- | ---: |
| `AskConversationModel.swift` | 1587 / 2513 (63.15%) |
| `Local/AskLocalEngine.swift` | 911 / 1044 (87.26%) |
| `AskLocalTools+Files.swift` | 45 / 53 (84.91%) |
| `AskFolderGrants.swift` | 118 / 118 (100%) |
| `Execution/AskHostCommand.swift` | 79 / 79 (100%) |

API production statement counters include turn dispatch 260/295 (88.14%), stock waves 108/122 (88.52%), prompt builder 64/69 (92.75%) and budget controller 124/149 (83.22%). Broader engine/worker error paths remain partially exercised; see the API measured report. This increment does not claim full production-path coverage.

## Reproduce and inspect

```sh
python3 docs/validation/gul-445/run-focused.py
python3 docs/validation/gul-445/export-coverage.py
```

The run script contains the exact suite/method selection. The issue attachment contains raw successful/preparation/failure logs, exact command/time JSON, source-relative Swift LCOV, Go profiles and the full source-hashed coverage reports for both repositories. Extract the Swift artifacts into this directory to inspect LCOV without a local build; export requires the instrumented binary/profile from the local command. API `summarize-coverage.py` reads all delivered `.cover` files by maximum hit count and verifies its source hashes. Production files stayed unchanged across retry scopes.

The generated `production-coverage.json` is compact review evidence for selected production paths. The attachment retains the full 548-file Swift export, including unexercised paths. Source hashes in both forms were checked against the checkout after execution. Profiles and SQL fixtures establish deterministic behavior, not provider quality or a latency improvement.

## Self-review and limits

Checked the full model/queue/engine/tool/store path, reopened requests and per-run defaults, duplicate receipts and provisional usage; absent/unknown/malformed state, denied device/peer, revoked folder/site and late callbacks; structured worker/process cleanup and temporary-file isolation; credentials/private projections and UI decision copy. Added original-run usage assertions during review. Corrected the inherited SQL test's shared deadline and new accounting assertions without changing production semantics. All selected tests now have passing evidence.

No implementation blocker remains in this increment. Real-provider quality/performance, live remote MCP and native-permission end-to-end behavior remain unverified; macOS uncooperative-writer limits remain as documented in the main matrix. GUL-453 was already accepted by the architecture owner: Swift #692 and API #155 are merged. Its stale board status is not an outstanding implementation review. This stage does not accept or complete the parent, deploy services or self-merge.
