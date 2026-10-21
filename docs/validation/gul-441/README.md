The parent acceptance corrections are complete locally. Current-source changed coverage is **648/692 (93.64%)**; the correction alone is **8/8 (100%)**. [Correction details, exact commands/timings, raw logs, source hashes and updated menu screenshots](correction/README.md) supersede the historical browser-history and four-choice presentation claims below. The final PR head is recorded in the handoff comment and PR description.

The remaining text records the initial `050b22c075d2f9dc147594110fe26e1b0c97acdc` delivery. Its run counts and timing are historical; current coverage reports at this path have been recomputed.

GUL-441 implements local task/conversation-session folder grants and revocation, exact browser-origin policy, and fresh consent for generic browser mutations. The base is accepted GUL-440 main, `aeda1f98e294e9f24406c3e0b1402a5570c1f9b7`. No Go or harness DTO changed. Architecture acceptance and merging remain with the parent.

Folder authority is an injected, locked, in-memory store. A local submission generation and exact message must be admitted before task roots execute. Owner, device, epoch, conversation, task/run, revision and descriptor identity constrain leases. Cancellation revokes local task authority without asserting remote termination; session grants survive task settlement and history retention, and expire on revoke, conversation deletion/discard, account reset or app exit. Historical labels and saved legacy paths do not restore grants. Settings/workspace sources remain independent, including overlapping roots.

The browser policy stores canonical HTTP(S) origins in an owner/device partition. Scheme, www, subdomains and nondefault ports stay distinct; default ports and IPv6 are canonicalized. Invalid/userinfo/non-HTTP origins cannot grant reusable site authority. Legacy allows remain inert; legacy denies retain the original stored-key/www matching, including Unicode hosts. Cookie rows cannot set permissions. Reads and page effects recheck origin, generation and policy around pauses/navigation. Generic click/fill requires fresh single-use consent even in YOLO. A completed/maybe-completed effect keeps its receipt if authorization or origin changes afterward, without exposing the changed page.

Production reusable operation approvals remain hidden. `AskConversationModel.drive` still constructs requests with `reuseEnabled: false`; the existing trusted peer/rollout gate is unchanged. Local reusable-grant metadata supports task or owner/device/epoch/conversation-session matching, exact arguments and the original five-minute cap, but this PR does not enable that production negotiation path. Directory access grants neither file-write approval nor shell access.

Validation evidence

Final changed executable-line coverage is **642/686 (93.59%)**, separate from project or branch coverage. Passing evidence contains **85 XCTest selectors and 59 Swift Testing method labels** across the focused runs. Timed runner invocations total **1864.91 s**, including preparation, discovery, failed attempts and correction runs; these were actual executions, not cached passing results. The separate successful `swift build` reported 49.25 s.

`test-results.json` lists distinct methods with passing evidence and every timed runner invocation, including failed preparation/fixture attempts. Coverage builds/discovers the complete test target but executes only the explicit suites/filters. No full unit/UI run, live external site, CI watch or self-merge was performed. Browser pages are synthetic WebKit HTML/local-file fixtures; the intentionally unreachable `.invalid` navigation only verifies safe local navigation status. The Settings source, workspace/admission/file barriers and descriptor replacements use actual production dispatch and temporary filesystem fixtures.

The initial scope was:

```sh
python3 scripts/test_groups.py --coverage \
  --suite AskFolderAuthorityTests --suite AskFolderGrantTests \
  --suite AskFolderSubmissionTests --suite AskAttachmentModelTests \
  --suite AskFileDispatchTests --suite AskBoundedFileToolsTests \
  --suite AskLocalApprovalTests --suite AskToolPolicyTests \
  --suite AskScopedApprovalTests --suite AskRecoverySafetyTests \
  --suite AskBrowserSitePolicyTests --suite AskBrowserWorkspaceTests \
  --suite AskEmbeddedBrowserToolTests --suite AskBrowserPanelRenderTests \
  --suite AskCommandJobLifecycleTests
```

`commands.json` retains the complete focused correction commands. Preparation failures and failed assertions are retained, not counted as passing checks. They include actor isolation, a mixed initializer link during an exploratory build, source modification during initial coverage preparation, two missing `try` markers in a new fixture, malformed IPv6 handling, a second normalization of a missing file during approval binding, old host-based assertions, and native accessibility/screenshot fixture assumptions. The HTML adapter fixture now explicitly disables independent host-code access and waits for two authorization callbacks before revoking the attachment source. Corrections preserved cancellation/commit semantics and did not relax waits or safety assertions. The small launcher screenshot uses its own 4 KB nonblank bound; existing large-panel bounds stay at 8 KB.

`changed-coverage.json` and `changed-coverage.txt` give the final changed executable-line denominator and uncovered lines. `coverage_report.py` includes an LCOV record only when the whole production source file's SHA-256 equals the current source; older counter layouts never add hits. Relative LCOV paths, source manifests and the exact base make the result portable. Recompute from this checkout:

```sh
python3 docs/validation/gul-441/coverage_report.py
python3 docs/validation/gul-457/changed_coverage.py \
  docs/validation/gul-441/matching-source.lcov.gz \
  --base aeda1f98e294e9f24406c3e0b1402a5570c1f9b7
```

Self-review checked submission/admission and receipt boundaries, source selection, owner/device/session isolation, lock/descriptor cleanup, pending/queued/failed cancellation, same-path regrant, pre-mkdir/staging/commit checks, exact operation matching, legacy migration, private tabs, cross-origin suspension, consent in YOLO, and truthful Settings/source copy. It found and fixed a fast terminal-observer/admission race, stale-binding regrant reuse, a precommit revalidation gap, post-effect receipt loss, a misleading expiry notice when Settings still authorizes the root, and permission-row overflow. Synthetic screenshots show the final menus; no chat layout changed.

Limits: executable-line coverage does not establish every branch, OS failure, arbitrary same-user filesystem race or live remote browser interaction. Uncovered executable lines remain listed, including attachment/picker bridges, defensive refusal paths and the successful live HTTP new-tab return. No new networking fixture or browser automation framework was introduced. Account/device isolation uses injected local identities; an OS-level sign-out or device migration was not exercised. Focused lint is not green: the accepted baseline and final touched files retain the same 19 error-level diagnostics (large legacy model code, force casts/tries, identifiers and long lines). New size-threshold crossings were removed by using extensions and isolating submission preparation/admission; the central approved-adapter switch has a narrow documented complexity exception matching the existing binding switch. `lint-baseline.json`, `lint-current.json` and `lint-comparison.json` retain the comparison.
