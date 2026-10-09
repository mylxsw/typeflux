# GUL-290 / GUL-276 client integration acceptance

This candidate contains the accepted GUL-296 session fences, GUL-299 launcher regressions and GUL-300 desktop fixture cleanup on the real client main, including clipboard PR387. The integration commit adds this evidence only. It does not change application code, tests, package configuration, migrations, display preferences or the accepted component commits.

The exact candidate's default native suite passed. Whole-application 90% coverage, strict repository lint and external production acceptance are **not** established by that result. This record is a client-side contribution to GUL-290, not a declaration that every cross-repository acceptance gate is complete.

## Source and component identity

GitHub heads were refreshed on 2026-10-09. All three component PRs remained OPEN / MERGEABLE / CLEAN; this is an unmerged candidate stack, not main.

| Component | Exact commit | Tree / base |
| --- | --- | --- |
| True client main, including PR387 | `34305bb348c8486aa5e97692e46f09285661547d` | Tree `498f6fe1a77eeab554c4476d4012a2365a907b29` |
| [PR388 / GUL-296](https://github.com/mylxsw/typeflux/pull/388) | `5785ba31143f7ad9e83a174ce348ecc392c787dc` | Base `main` at `34305bb348c8486aa5e97692e46f09285661547d` |
| [PR389 / GUL-299](https://github.com/mylxsw/typeflux/pull/389) | `32ed903ab848c3c76075efdee1521726dc597520` | Base `gul-296-session-fence` at `5785ba31143f7ad9e83a174ce348ecc392c787dc` |
| [PR390 / GUL-300](https://github.com/mylxsw/typeflux/pull/390) | `a27cffdddb642adf9d92739eabe8bcc5e7944971` | Base `gul-299-launcher-regressions` at `32ed903ab848c3c76075efdee1521726dc597520` |
| Tested client candidate | `a27cffdddb642adf9d92739eabe8bcc5e7944971` | Tree `3414b1f94ec1dc86492e6e625e05d2640b211df0` |

The integration branch descends from a27 and targets main. Local `git merge-base --is-ancestor` checks verified every listed dependency, including true main. Comparing main with a27 gives 6 production files and 15 test files; the documentation commit adds no source changes. All 1,237 tracked files under `Sources`, `Tests`, and `Package.swift` match accepted a27 byte for byte. No extra source or temporary probe is present.

The public/native source fingerprint is `fdc3492dc46209145a46f895b4e7c177c6bbf07f9c8a646cc80dcded08aeff66`. It was independently recomputed in this integration checkout. It is SHA256 of sorted UTF-8 lines, each `SHA256(file)`, two spaces, relative path, newline. Reproduce from the repository root:

```sh
python3 - <<'PY'
import hashlib
import pathlib
import subprocess

paths = subprocess.check_output(
    ['git', 'ls-files', 'Sources', 'Tests', 'Package.swift'], text=True
).splitlines()
manifest = ''.join(
    hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest() + '  ' + path + '\n'
    for path in sorted(paths)
)
print(len(paths), hashlib.sha256(manifest.encode()).hexdigest())
PY
git diff --exit-code a27cffdddb642adf9d92739eabe8bcc5e7944971 -- Sources Tests Package.swift
```

## Native evidence reused without a new execution claim

GUL-300's independently accepted `review2248-review.md` and `review2248-evidence.zip` are the provenance for this table. Their small source/native summaries are retained alongside this document as [accepted-source.json](accepted-source.json) and [accepted-native.json](accepted-native.json). No macOS job was started for this documentation-only integration; the exact source identity above is the reason reuse is valid.

| Check | Accepted execution and result |
| --- | --- |
| Final build and default `swift test` | Native worker `c41e8a77-2f60-4b3d-9e15-6a0f300a0c03`: BUILD_EXIT 0, TEST_EXIT 0, worker exit 0 |
| XCTest default total | 3,218 tests, 16 skips, 0 failures |
| Swift Testing default total | 2,035 tests / 313 suites passing; separate environment-gated tests remain skipped |
| Affected native repetitions | Three runs, each 8 XCTest / 1 existing skip / 0 failures and 18 Swift Testing / 5 suites passing; actual TEST_EXIT 0 each |
| Final full raw log | 1,333,011 bytes; SHA256 `abe9fb4d0e3d4fa51965f3d6c41a72ecae43d2d1dba150cf8c4cb8b812788706` |
| Final wrapper | SHA256 `d7aa0b4bcf05b0d93d57de16ff85a540494b31f1699a6acef54076d1ab094267`; returns the captured `swift test` status with `exit $T` |
| GUL-296 focused tests | 151 actual macOS ASR/Auth tests pass at 5785, then five passing repeats; relevant production and test files unchanged by PR389/390 |
| Meaningful negative controls | 17 new session/profile tests failed on the earlier unchanged-main baseline; accepted cleanup probes without the new defers produced 14 issues / NEG_TEST_EXIT 1 |

All six GUL-300 cases and the three GUL-299 cases passed in the final default run. These preserve AI-last ordering, strong/weak match selection, an owned empty app index, observable AX readiness, window ownership, width/height and anchoring/clamping, ghost-row and menu geometry, intermediate animation frames and reduced-motion cancellation assertions. Earlier failing full runs at PR388/389 are historical, not the final result. No old wrapper's outer success is used as evidence of a passing test command.

The positive cleanup probes observed result documents/windows and isolated defaults being removed after early throws; motion throw/cancel probes restored launcher, AX, model and defaults state. The executed motion-cancellation path cancels and joins its task. The deleted temporary driver's unexecuted outer polling/require error exits only cancelled and did not join; they are unverified, are not shipped, and must not be reused as a cancellation-safe harness. Existing five geometry negative controls and 30 idle/load animation cases are reused unchanged, not claimed as rerun.

## Consumer contracts and F01–F16 handoff

| Original finding | Client evidence and exact acceptance boundary |
| --- | --- |
| F01 webhook retry / exactly-once grants | API-owned durable webhook/ledger behavior. Client billing presentation cannot prove a payment was committed exactly once; cross-repository API acceptance is required. |
| F02 verification-code lockout | API-owned counter/lockout transaction. Client error presentation is not evidence of backend guessing protection. |
| F03 refresh-token replay | `AuthStateTokenRefreshTests`, `AuthStateProfileSessionTests`, and separate live concurrent-refresh/replay cases cover shared exchange, revoked-family logout without loops, relogin, transient failures and stale results. API atomic rotation remains the server authority. |
| F04 password change / revoked access | Separate live password-change case verifies another device is rejected and the password is restored. Profile tests cover fresh-token renewal before profile fetch, generation checks after profile/subscription awaits, replaced-login notification suppression, and stale subscription/usage/breakdown results and loading flags. |
| F05 ASR grant reuse | `TypefluxOfficialASRGrantFailoverTests`, `TypefluxOfficialASRAttemptBoundaryTests`, `TypefluxOfficialASRSessionFenceTests`, and `TypefluxOfficialASRGatewayFixtureTests` preserve a fresh one-use grant per pre-admission attempt, same-session rotation, checks after route/replacement/selection awaits, cancellation and no replay after audio/nonempty partial/LLM progress. Real local dual-gateway cases and the separate live claim/debit checks supplement mocks. The fence starts when transcription acquires its credential; binding at the earlier Workflow microphone-recording start is not covered. |
| F06 same-second subscription ordering | API canonical-state/concurrency acceptance is required. Client profile and subscription generation guards prevent stale account data but do not order Stripe events. |
| F07 customer / pending Checkout exclusion | API and homepage own durable pending reservations, reuse, price change, unknown creation, 409, cancellation and tab/token redirect guards. Native billing tests cover the consumer API/presentation; this record does not relabel them as browser or Stripe acceptance. |
| F08 dependency vulnerabilities | API/ASR/frontend scan results belong to their exact components. GO-2026-5932 module-only and ASR stripped-binary scanner exit 3 remain explicitly unresolved elsewhere. |
| F09 subscription reconciliation | API outbox/recovery and lifecycle-field acceptance is required. Native account refresh and generation tests are consumer evidence only. |
| F10 ASR callback credential forwarding | Gateway allowlist/redirect protection is server-owned. Client ASR tests do not prove callback SSRF prevention. |
| F11 Aliyun data race | The ASR server's race suite is authoritative. Client two-gateway tests are complementary, not a substitute. |
| F12 body / WebSocket resource limits | Server limits remain authoritative. Native attempt-boundary and gateway cases verify cancellation and no replay after admission. Client feedback preparation and API errors are supplementary. |
| F13 feedback upload size and ownership | `FeedbackAPIServiceTests`, `FeedbackUploadFlowTests` and the separate live feedback cases cover trusted ticket → API PUT → feedback; relative issuing-origin and configured canonical-origin tickets; exact scheme/host/port; no bearer on arbitrary legacy storage hosts; false size, other owner and anonymous cross-use rejection. API/storage resource limits and delayed cleanup require server evidence. |
| F14 DELETE CORS | Browser/API-owned; native requests are not subject to CORS. No native test is counted as browser preflight acceptance. |
| F15 private-IP rate-limit bypass | API/proxy configuration and Redis-failure tests are authoritative. Live fixtures relaxed auth/feedback rate limits explicitly; those fixtures are not a production rate-limit test. |
| F16 default tests / reproducibility / coverage | Exact a27 native default suite is accepted as above. Strict lint, coverage scope and environmental exclusions below remain separate acceptance facts. |

### Settings feedback and live evidence

`SettingsView` uses `FeedbackUploadFlow.upload` and records `FeedbackUploadOwner`; submission reads the current credential again and rejects uploads from another sign-in. Ticket and PUT share one credential. Submission after same-session rotation uses a fresh token; it is incorrect to claim all three requests always use the identical bearer. Canonical API A is accepted from failover issuer B only when A is a locally configured API endpoint. Otherwise the deployment must issue relative tickets. Response-controlled hosts do not become trusted. Legacy HTTPS storage uploads strip supplied Authorization and receive no account bearer.

The accepted provider-free live run used client `2f204e2735e0df0a655016f058101079d39ec1ab`, API `51fa182215dd93b7565d7a019bbcd8787f43ce29` and ASR `c38a09aed63fb261948f095ba8b7115c22c5c0cf`, with cold isolated PostgreSQL 16, Redis 7 and RustFS, two API nodes and two ASR gateways. Disposable accounts went through real registration/activation, without rewriting `created_at` or deleting settlements. All 8 native live cases passed twice after the cold restart. Four grants across those two runs had one claim and settlement each; replay was API 409 / gateway 403, and the second gateway established no session. Audio admission failure used one grant and no second gateway. Password restoration and resource cleanup were reported complete.

The Settings live case invokes the production upload/ownership flow and real services, including canonical A from issuer B, rotation before submission, account-switch rejection and rejection of unconfigured A. It is not an interactive click-through of the Settings window. The earlier real Chromium evidence records 17 browser responses and 54 repeated/concurrent API reads, all 200, on homepage `f5bca08dcd308e2a5d3d5745db8790a21d32e997`. This is separate historical live evidence, not a new a27 live run. PR388's added session behavior is established by its native positive/negative tests and the final a27 full suite, not retroactively by the older live run.

The default a27 suite skips all eight `TypefluxLiveContractTests`. The other XCTest skips require interactive browser/desktop permissions, snapshot flags, a Go-to-Swift release bridge or a dedicated Settings-menu process. Swift Testing also reports environment-gated benchmark/credit-pause/context-menu skips. A green default command does not turn these into executed live checks.

## Lint and coverage are separate gates

| Scope | Accepted result |
| --- | --- |
| GUL-296 changed executable production lines | 119/126 = **94.4%**; seven uncovered lines are in the real routing `testConnection` path |
| The same six production files, LLVM whole-file line coverage | **80.08%** |
| The same six files, LLVM region coverage | **71.83%** |
| Whole application | No final 90% claim; the scoped figures above cannot establish it |
| Production Swift strict lint at GUL-296 | **1,632 findings** on both candidate and baseline, unchanged per-rule counts in affected files; not green |
| Six GUL-296 changed test files | Two existing line-1 `blanket_disable_command` findings; no new findings reported |
| GUL-300 final two-file strict lint | Exit **2**: one `function_body_length` in `AskLauncherMotionTests.swift:45` (85 counted lines; base 86), two `line_length` findings in `AskResultDocumentTests.swift:145` and `:213` (127 and 122 characters); identical base rule counts |

The approved 80% floor, modified-module >80% requirement and overall 90% target are different measures. Test-only geometry/cleanup and this documentation commit increase no production coverage. The API's separately accepted overall 88.3% is also below 90%; it is not client coverage. No exclusions, assertions or lint rules were weakened here.

## Deployment, rollback and remaining limits

The integration composite uses API `51fa182215dd93b7565d7a019bbcd8787f43ce29`, homepage `703be8a2766775d20be80a3400619e3645c667ad`, ASR `c38a09aed63fb261948f095ba8b7115c22c5c0cf`, and dashboard `fd42029365429e79e12302e506046eb6ade0f530`. Those repositories own migration numbering/order, rolling compatibility, worker drain, pending commit+ACK, durable recovery/cleanup intents, Redis tombstones, and route inventory (135 registered / 105 protected). Client source identity does not establish those server checks.

No database migration or wire-format change is added by the client stack. GUL-296's production delta rejects stale sessions before ASR transport and stale account loads after awaits; PR389/390 only change tests. Deploy compatible API/gateways with one-use grants and bounded feedback tickets before distributing consumers, and ensure canonical feedback origins are configured locally. Roll back this documentation commit independently. Reverting PR389/390 reintroduces test-fixture assumptions; reverting PR388 removes session/consumer protections and requires an explicit security decision. Server rollout/rollback must preserve already applied migrations and durable recovery data; it cannot be inferred from reverting the client.

Before merge, refresh actual main/component heads. If an external merge changes ancestry, compare source content as well as commits; preserve accepted consumer, launcher and PR387 clipboard changes. Do not push to old merged/deleted component heads, and do not treat this PR as permission to merge or deploy.

Remaining acceptance limits: real Stripe payments/providers, system permissions/signing, 24-hour upload expiry/cleanup, hosted PG16/17 CI blocked by account billing/spending limits, the scanner exceptions above, the pre-transcription recording-start binding boundary, whole-app coverage and strict lint. Existing short-screen clipboard/Dock occlusion (~34 pt), old `AskTestFixture` temporary-directory/defaults behavior and finite unchanged gateway-fixture ownership limits are disclosed; this acceptance does not assert all-screen/all-lifecycle correctness. GUL-274/275/277 and independent GUL-298 are outside this integration.

## Integration self-review

Checked real remote heads and ancestry; source-tree/file identity; post-await session checks and fresh-grant/error/cancellation paths; feedback trust and credential ownership; owned gate/task/listener cleanup in changed tests; preservation of geometry assertions and localization isolation; exact native test exits, negative controls, skips, lint counts and coverage scopes. Local `git diff --check` passes. Only English acceptance documentation/evidence was added, and no credentials, raw account data or temporary validation harness was committed.
