## Delivery boundary

The independent executor core was merged in PR #266 as
`2e5130f8ca4867ad2438e785acd22d19366f20d5`. The follow-up connects both
production `AskLocalTools.execute` and `executeApproved` to those executors
and removes the previous parallel AppleScript/CGEvent implementations.
Browser/computer writes remain **disabled by default**, including the legacy
entrypoints. Read-only browser observation, desktop inspect/wait and screenshot
consent remain available. Native granted-path acceptance is still required
before enabling writes; see `p09-validation.md` for the current evidence.

The integration foundation is P06 adapter PR #265's reviewed, delivered fixed
head `2ece25153b3ce3d4beccff6ea3ad89ca25ddb703`, based on main
`2e5130f8ca4867ad2438e785acd22d19366f20d5`. It includes final P02 #261
(`fe1d68e4`), P06 core #262 (`2506ffcd`) and P09 #266 without repeating the
superseded prerequisite commits. Shared-file integration began after P06's
implementation run completed and its author released this exact foundation.
P06 subsequently merged as `bfc927cdfb1fdfd91acfa4a17710acdf741a4c75`.
The follow-up branch was moved to main `658e291ab5c6e62eed29abb3fae1595bb835afee`;
the latter adds design documents only, with identical production/test sources.
Its PR base is main and contains no duplicate P06 commits. P06's raw/approved MCP result adapter and the P02 folder grants, pending-call
comparison, journal claim, grant consumption and late authorization callback
are preserved. No other PR is merged automatically.

## Production routing

Each `AskLocalTools` instance owns one observation store and its two executors.
Scopes come from the trusted owner, conversation and tool, never arguments.
Rebinding a conversation invalidates its observations. Owner/rebind changes
are checked again after asynchronous preparation and during dispatch. Browser
writes select the browser recorded in the local observation; they never fall
back to a different running browser. The default AppleScript runner now uses
`AskAutomationScriptRunner`'s bounded process contract.

Both entrypoints require fresh `observation_id` values for writes. The tool
schema advertises string refs; numeric refs are rejected even if a selector
is also supplied. Desktop scroll requires x/y inside the observed window.
`approvalBinding` delegates to executor binding, retains schema identity and
`allowsReuse = false`, and passes the exact approved target and authorization
callback to execution. Tests enable writes only on injected fixtures; there is
no production setting or capability-negotiation change that enables them.

`AskScreenObservation` handles screenshot consent when a stable AX target
cannot be obtained. It binds display identity/topology, checks the returned
display and authorization after capture, and clears older write observations.
Its result carries an image but **no write observation**. A display mismatch or
permission failure cannot silently become a successful capture of another
screen. When AX evidence is available, screenshots go through the computer
executor and can establish a normal target-bound observation.

Receipts set `AskLocalToolOutput.outcome` and its trusted observation field;
P06's `record` path preserves them in the journal/cache and local message
projection. Legacy text still contains dispatch/effect evidence, so disabling
typed wire negotiation does not turn an unknown effect into success. Persisted
observations are diagnostic evidence only: reopening/restarting never restores
the in-memory authority to write.

## Local evidence and execution

`AskObservationStore` keeps only the latest observation per owner, conversation
and tool. It uses a monotonic 120-second lifetime, a fresh opaque UUID, local
target evidence and a bounded in-memory store. A model may supply only an
`observation_id`; it cannot supply authoritative process/window/tab identity.
Re-observing replaces the old version. A write attempt consumes its observation
before dispatch, including attempts whose effects become unknown. Restarted
sessions and legacy numeric refs require fresh observation.

`AskBrowserExecutor` checks the running browser process instance and pins its
OS window/tab, URL and document time origin. `read` and `snapshot` install a
versioned, one-shot page closure retaining actual element objects. Refs have
the form `<observation UUID>:<one-based index>`. The closure drains mutation
records in the same JS turn as the action, and checks URL, document generation,
viewport, scroll position, element connection and geometry. Blur, visibility,
pagehide and history events also invalidate the closure, including switching
away and back before acting. CSS selectors also
require a fresh observation and may only resolve to an observed element.
Missing elements, malformed selectors, unsupported fill targets and disabled
fields return `invalid` with `event_dispatched: false`.

Supported fill targets are textarea, text/search/url/tel/email/password/number
inputs, and contenteditable elements. Native value setters and bubbling input
and change events support controlled inputs. `effect_verified: true` means
only that the immediate field value survived those events. It does not mean
submission, server persistence or any other business effect succeeded. Number
or single-line input sanitization may prevent that immediate verification.

`AskComputerTargetProbe` binds the application PID/launch time, AX window and
focused element identity, exact window geometry, display identity/topology and
an AX tree fingerprint that retains element identity. It does not follow the
mouse to select a display. Another foreground application, missing permission,
terminated process, changed window or display requires fresh observation.
`AskComputerExecutor` validates before and after activation, then checks window,
display and focused control identity between input batches. Events are built
before dispatch. Once mouse-down is sent, synchronous `defer` releases it at
the last delivered position on cancellation, revocation or target change.
Scroll coordinates are required and its event location is pinned explicitly.

`AskAutomationScriptRunner` uses P01's bounded `ManagedProcess` contract for our
short-lived osascript client: minimal environment, bounded output, 22-second
deadline and cancellation cleanup. It does not contain arbitrary escaped
descendants and cannot undo Apple Events already delivered to a browser.

`AskActionReceipt` projects the frozen outcome/observation DTOs into legacy
text so event delivery and effect verification stay visible without negotiating
new wire capabilities. Unknown transport results after dispatch are errors
requiring observation and reconciliation, never automatic replay. Text is
bounded with an explicit truncation marker; observation evidence stays separate.

## Security and compatibility limits

- AppleScript executes in the page's JavaScript world. Page code can tamper
  with globals and APIs; this is stale-target protection, **not hostile-page
  attestation**. No reusable browser or desktop grant is enabled.
- AX reads and event posting are not one OS transaction. Missing or unstable
  evidence fails closed; real acceptance is required before enabling writes.
- AX inspection retains the existing bounded tree depth/node limits. It does
  not prove identity of inaccessible or omitted controls.
- Cross-frame access, downloads, profiles, general effect inference and new
  recovery/replay behavior are outside this change.
- Existing read-only screenshot consent must remain available in the final
  adapter even when AX target evidence is unavailable. Such a screenshot must
  not issue a usable write observation. Never substitute another display when
  capture returns an unexpected display ID.

## Acceptance still required before rollout

Real Safari/Chrome tab/window/navigation and macOS granted/denied permission
acceptance must complete before enabling writes. WebKit DOM and injected
executor tests are controlled regression tests, not substitutes for that
acceptance. Keep authorization reuse off and unknown outcomes unresolved;
never automatically replay a partially dispatched action. Missing permissions
are reported separately from compilation, unit tests and full-suite failures.

## Reproducible fixtures

The deterministic tests exercise a real WKWebView DOM as well as injected
executor races. They are not Safari/Chrome or desktop permission acceptance.

```sh
swift test --filter 'Ask(AutomationIntegration|LocalTools|LocalApproval|AgentTools|BrowserDOM|BrowserExecutor|ComputerExecutor|ComputerTargetProbe|ObservationStore|AutomationScriptRunner|ScopedApproval|ToolPolicy|TypedContentIntegration)Tests'
TYPEFLUX_AUTOMATION_ACCEPTANCE=1 swift test --filter AskAutomationAcceptanceTests
make coverage
```

The explicit acceptance invocation fails, rather than silently skips, when
Automation/Accessibility permission is missing. Normal unit runs skip the
three interactive acceptance cases and report those separately. The browser
fixture creates a new controlled window and closes only that window. The
standalone desktop fixture logs actual mouse events, exits after 45 seconds
and is terminated/reaped by its harness. No TCC database or browser preference
is changed automatically. `browser-observation.html` can also be served from a
local HTTP server for manual navigation and tab-change acceptance.
