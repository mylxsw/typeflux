# Local web_fetch connection boundary (GUL-174)

## Decision

Local `web_fetch` is disabled. New local runs omit its definition; direct calls
and calls from persisted runs return an explicit error before DNS resolution or
network I/O. There is no setting, environment variable, or injectable URLSession
that enables it. No request is forwarded to the cloud as a fallback.

This implements the task's fail-closed option. It does **not** deliver a new
working HTTP transport. Local search still uses the user's configured provider
and key. Browser access and managed preview loopback access are separate domains;
neither is automatically invoked as a fallback or granted an exception here.
The local engine state machine, shared DTOs, and cloud API are unchanged.

## Evidence and limits

The starting point was a **risk requiring verification**, not a confirmed
real-network DNS rebinding exploit. At baseline `e46a10d`, `fetch` checked the
host with `getaddrinfo`, submitted the original hostname to URLSession, and
checked the final response URL again. The checked addresses were never supplied
to the connection operation. The redirect delegate had the same separation.

`AskLocalWebBoundaryTests.testPreflightAndFinalDNSChecksDoNotBindTheConnectionPeer`
reproduces that sequence with a controlled resolver and URLProtocol connection
substitute. Both application checks see public IPv4/IPv6 addresses. The
substitute selects loopback, private IPv4, IPv6 loopback, or IPv4-mapped loopback
and returns a private sentinel. Both checks pass and the sentinel is readable.
The refusal regressions were also run against the original production fetch:
six tests produced 36 failed assertions before the change.

This demonstrates the missing binding under controlled substitutions. It does
not demonstrate CFNetwork's real resolver/cache timing, a real private socket,
or a live TLS/proxy attack. It does show why another preflight lookup or checking
the final URL cannot establish the required invariant.

Apple documents [URLSession task delegate events](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate)
and [remoteAddress transaction metrics](https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics/remoteaddress).
Our conclusion for this implementation is that response/transaction observations
cannot prevent a connection that has already happened. The existing URLSession
HTTP path has no verified binding from the checked addresses to its socket
selection. Changing an HTTPS URL to an IP and accepting trust manually would
introduce a separate hostname-validation obligation; this patch does neither.

The cloud implementation is a useful semantic comparison, not a Swift guarantee:
`typeflux-api/internal/ask/webtools.go` checks the numeric destination from
`net.Dialer.Control`, disables environment proxies, validates redirect URLs,
and leaves standard TLS validation enabled. No Go production code is changed.

## Behavior matrix

| Input or condition | Local fetch result |
| --- | --- |
| Public hostname; public or private numeric IPv4/IPv6 | Explicit unavailable error; no resolution or request |
| DNS changes from public to private | Same refusal before either lookup |
| IPv4-mapped IPv6 | Same refusal; no alternate literal-address path |
| Public response redirecting to a private URL | Initial request refused; no redirect hop |
| Environment HTTP/HTTPS/SOCKS proxy or URLSession proxy configuration | Same refusal; no proxy or direct connection |
| Invalid certificate / hostname | No TLS handshake; no trust override or hostname rewrite |
| Oversized response or slow/trickling response | No response stream or buffer is created |
| Malformed JSON tool call | Existing argument-parser error; no network |
| Old persisted run advertising fetch | Error tool result, no device dispatch, run can continue |
| New run inventing an unadvertised fetch call | Existing invalid-tool validation fails the run |

The slow, oversized, redirect, and TLS substitute scenarios test **refusal before
transport**, not successful operation of a streaming limit, redirect handler,
or certificate validator. Offline HTML helpers and address-policy tests remain;
their presence is not evidence that fetch is available or safe to re-enable.
Search retains the original platform TLS handling and redirect preflight. That
preflight is explicitly not presented as a general socket destination guard.

## Requirements before restoring fetch

Restoration needs a separately reviewed transport and integration acceptance;
restoring the removed URLSession path or adding a boolean is not sufficient.

- Bind every connection attempt, retry and address-family fallback to validated
  numeric public destinations; reject unresolved or unverifiable peers before
  any request bytes. Cover IPv4, IPv6, mapped addresses, and address transitions.
- Preserve original-host TLS certificate/hostname verification and SNI. Test
  both a trusted matching certificate and untrusted/mismatched certificates on
  the actual transport; do not accept server trust unconditionally.
- Specify proxy behavior, including environment and system/PAC settings. A proxy
  must not introduce unchecked DNS or private destinations; otherwise refuse.
- Reapply the policy at every redirect, with a finite hop count. Do not turn a
  redirect rejection into a successful result for the original URL.
- Bound decompressed bytes (the previous cap was 2 MiB), returned text (40,000
  characters), headers, and the entire request/redirect/body lifetime (20 seconds
  was the prior request timeout, not a proven total deadline). Cancellation and
  deadline expiry must close the connection and response stream.
- Run actual socket/TLS/proxy fixtures as well as deterministic substitution
  tests. Browser and managed-preview exceptions must remain outside this tool.

## Validation

Executed on 2026-10-03 with Swift 6.4 on macOS arm64:

| Check | Actual result |
| --- | --- |
| Baseline `swift test --enable-code-coverage` at `e46a10d` | 2,547 XCTest cases passed; Swift Testing ran 565 tests, with one failing test / four assertions |
| Original production code plus initial boundary regressions | Six tests run; the legacy-sequence reproduction passed, five refusal tests failed with 36 assertions |
| Modified production code, `make coverage` | 2,556 XCTest cases passed; Swift Testing ran 565 tests with the same one failing test / four assertions; command failed |
| Final Web/engine tests, all six upper/lowercase HTTP/HTTPS/ALL proxy variables set to loopback | 21 passed (includes the subsequent test-only addition for both providers' search results) |
| Audio and ASR cache tests rerun to investigate coverage variation | 57 passed; no production changes to either module |
| Go public-address / dialer / fetch semantic comparison at `2868c90`, `go test -race` with coverage | Four tests passed; no database-dependent tests selected |

The full-suite failure on both baseline and modified production code is
`AskAccountFooterClickTests.swift:37,39,43,44`, in
`accountNameClickTogglesTheAccountCard`: account-card presentation/visibility and
pointer containment expectations. It is not a newly introduced fetch failure.
No explicit skips were reported. The existing keychain test conditionally checks
the successful-write path; that path was not covered in this environment.

Because `make coverage` exits on the full-suite failure, its report-generation
step did not execute. Current-run profiles were merged with `xcrun llvm-profdata`
and inspected with `xcrun llvm-cov`; the baseline profiles were kept separate and
were **not** merged into the modified-code result. The final aggregate includes
the full run and the two successful targeted runs above, all on the same
production code. No full-suite pass is claimed.

| Coverage scope | Baseline | Modified code, current-run aggregate |
| --- | --- | --- |
| Entire `AskLocalWebTools.swift`, executable lines | 265/290 (91.38%) | 252/257 (98.05%) |
| Same file, functions | 60/80 (75.00%) | 69/73 (94.52%) |
| Same file, regions | 168/199 (84.42%) | 154/163 (94.48%) |
| Whole repository, executable lines | 61,920/122,768 (50.4366%) | 61,900/122,735 (50.4339%) |

The modified-module 90% goal is met. The literal whole-repository percentage
non-decrease goal is **not** met: the remaining difference is 0.0027 percentage
points. File-by-file comparison attributes it to removal of the old, covered
fetch path (33 fewer executable lines, 13 fewer covered lines in the changed
file) and seven fewer covered lines in the unchanged
`AVFoundationAudioRecorder.swift`. All other files match the baseline covered
line counts after the targeted variance check. This residual measurement and
the existing UI failure remain explicit acceptance limitations.

Whole-repository reporting uses the repository script's `.build|Tests` filename
exclusion. Go's focused semantic comparison covers 132/225 statements (58.67%)
in `webtools.go`, or 132/1,606 (8.22%) across the entire Ask package; this is not a
full Go-package coverage run or a claim about a modified Go module.

No live DNS rebinding, TLS certificate/hostname, or proxy handshake integration
test was performed; the shipped fetch path never reaches those operations.
No manual desktop, real-model, or database integration acceptance was performed.
Restoring a working fetch transport still requires the validation listed above.
