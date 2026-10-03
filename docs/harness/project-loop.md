# Project loop integration (GUL-179 / D04)

This connects D01 manifests, D02 execution and D03 artifacts in explicitly
constructed test hosts. Production `AskLocalTools` retains project mode off, a
nil runtime and artifact creation/preview off. No settings switch, rollout,
protocol negotiation or other stage-one capability is enabled.

## Authority and lifecycle

`project_terminal` supports start, input, status, output, preview and stop. The
model supplies opaque workspace/lease IDs; the host resolves its current owner,
conversation, run and app session. Private-conversation routing keeps the account
authority distinct from its local cache partition. It cannot choose a PID, URL or runtime path.
Launch approvals display the complete effective request, defaults, cwd,
deadlines and source root. The P02 journal consumes the single-use grant. Only
inside validated dispatch does the adapter derive a narrow D02 grant for the
exact request/input. D02 rechecks the outer dispatch after preparing the copy,
immediately before consuming the inner grant and spawning. Each input/EOF needs
a fresh approval. Unknown journal outcomes remain non-replayable.

Output uses absolute byte cursors, retains incomplete UTF-8 across pages, and
displays gaps/truncation. The terminal card shows actual state, exit code and log
failure, with an immediate Stop control. Readiness is not command success or
project completion. Stop, conversation deletion, account reset, task cancellation
and a replacement run cancel the processes. D02 retains revocation, timeout,
workspace invalidation and application-exit handling. Its new invalidation
subscription closes previews synchronously on explicit Stop/revocation; natural
exits/timeouts are observed by the existing 250 ms timer.

## Preview boundary

A URL/DTO alone still fails closed. `AskDevelopmentPreview` requires a real
nonce-ready D02 lease and binds its exact IPv4 origin, full identity and scope.
Every suspended resource read validates before and after transfer. A different
active lease, run, account or app session cannot borrow it.

WebKit stays offline. D03's fresh nonpersistent view, random custom-scheme
origin, CSP, content rules and verified engine switches are retained. The host
proxies GETs for a complete explicit list of relative resources to the one live
HTTP origin, replaces service headers with restrictive preview headers, and
disables redirects, proxies, cookies, credentials and cache. Limits: 16 MiB per
resource, 32 MiB per preview, 128 declared resources, 256 requests and 3/5 second
request/resource deadlines. Actual bytes are counted independently of headers.
Close/Stop cancels transfers and detaches the executable page.

This supports the delivered HTML/JS/CSS adapter. It does not enable page
fetch/XHR, WebSockets, hot reload, workers, arbitrary web apps, remote resources,
file access, uploads, native bridges or package installation. D03's WebKit SPI
compatibility limitation remains; this is not an App Store distribution claim.

## Evidence and delivery

`preview` waits for actual WebKit loading, observes DOM text and diagnostics,
captures PNG pixels and rechecks errors and authority before publication. It
publishes screenshot/JSON evidence through `AskArtifactStore`. Errors reject
successful preview publication. The card may open a new live capability while
the same service remains ready. Error/console instrumentation is an observation,
not a security attestation: hostile page code can tamper with its own hooks.
The test exit code, resource policy, expected rendered content and pixels are
independent checks. Captures do not prove that an arbitrary application works.

HTML/resource artifacts continue through D03 `AskArtifactCapture`, validating
all declared source versions and staged bytes. No runtime-directory snapshot
adapter is introduced. A service can generate content different from its
source: the screenshot describes the service; the source artifact describes the
validated manifest. Exports are original entry files, not multi-file archives.
Artifacts remain device-only, hash checked, and retained for 30 days.

## Reproduction

`d04-fixtures/frontend` contains a requirement, HTML/JS/CSS, a stdlib checker and
an inherited fd-3/nonce server. `static` is an independent standalone page.
Neither fixture needs npm/pip or downloads. Tests execute private staged copies
and check that source files remain unchanged.

```sh
TYPEFLUX_D04_EVIDENCE=/absolute/path/to/evidence \
  swift test --enable-code-coverage \
  --filter 'AskProjectLoopTests|AskDevelopmentPreviewTests|AskTerminalIntegrationTests|AskProjectProtocolTests'
make coverage
```

Evidence includes actual diff, exit status, readiness, DOM, console/errors,
snapshot hash, open/export hashes and measured process/port cleanup. The API
repo's optional `TestMeasuredProjectEvidence` reads those files and verifies the
PNG digest. `CheckProject` does not accept model text as evidence. Evidence JSON
must come from a trusted harness; it is not a signed attestation format.

Local, Cloud + Cloud and Cloud + custom protocol fixtures run separately from
real execution and live-model acceptance. See `d04-validation.md` for results.

## Remaining gates

Execution remains offline CLT Python, one process, no shell/subprocesses or
package installs. CPU/memory/copy-disk quotas and a crash-proof external guardian
are absent. Normal Stop cleans up; host SIGKILL can leave a sandboxed orphan.
Historical numeric PIDs are never signalled during recovery. Live model/provider
and Safari/Chrome/desktop permission matrices, other OS/WebKit versions,
interactive save panels and human review remain separate gates. Rollback stops
the runtime and closes previews while retaining artifacts/logs.
