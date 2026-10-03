## Delivery boundary

This PR delivers the independent P09 executor core and controlled acceptance
fixtures. It does **not** finish GUL-175: production `AskLocalTools` and
`AskLocalTools+Approval` still use their existing implementations. The final
adapter must be integrated serially after P06 publishes its fixed adapter
commit, preserving its shared raw/approved MCP result adapter. Both new
executors default to `writesEnabled = false`; no production capability is
enabled by this PR.

The initial dependency was P02 `d53c0ddc2bc11a6e8917b2480cf31b5f29137976`
(PR #261). P02 then merged main to resolve conflicts. After reviewing the
changes to approval binding, attached-folder scope, pending calls and steering,
this branch fast-forwarded to the reviewed fixed commit
`a9ebc93d5f2788e49f4155a78223ad35f3ae5d8a`. P02 subsequently squash-merged as
`fe1d68e446d715ad9f20e3517d2c170191ec4af9`; P09 was moved onto that main
commit without repeating P02's commits. **The PR base is main.** The P06 core
head observed during this work was `756fb4473da7aa5475d2792a17c6c3ab78bb739c`
(#262), and the delivered adapter was
`390c466f46c41447bb31d0f59671b593005d7e72` (#265). Neither is imported here.
The user requested a further #262 conflict repair at 10:41 UTC. P06 completed
that repair at `297e812391d38adddc5c744659282ec51ee0f643`, but adapter #265
remained at `390c466f...`, conflicting with current main and still including
the superseded core/P02 prerequisites. Final shared-entry integration needs a
refreshed compatible adapter foundation; this PR does not copy or redo P06's
shared adapter to bypass that dependency.

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

## Serial integration requirements

1. Read P06's delivery and fixed adapter commit; inspect both P02/P06 PR states.
   If #261 merges, move this change to updated main and retarget its PR without
   reintroducing P02 commits. Re-run the combined tests after integration.
2. Give each `AskLocalTools` instance one store and its executor instances.
   Create scopes from the trusted owner and conversation, not model arguments.
   Keep a bound browser/process selection for each observation.
3. Advertise `observation_id` and string refs for write actions; require `x,y`
   for desktop scrolling. Do not silently accept old numeric refs. Keep write
   capabilities disabled until desktop and combined acceptance are complete.
4. Use executor `binding` in `approvalBinding`, preserving `AskToolBinding`,
   tool/schema identity and `allowsReuse = false`. Pass the exact binding target
   and the existing `authorize` callback into execution. Preserve pending-call
   revalidation, journal claim, grant consumption and late revocation checks.
5. Route both raw and approved computer/browser calls through the new executor.
   Remove the old event/JS implementation only after its tests migrate. Leave
   P06's shared MCP adapter and the folder-grant changes intact. Adapt receipts
   through P06's outcome/typed-content projection without enabling negotiation.
6. Complete real Safari/Chrome tab/window/navigation and macOS granted/denied
   permission acceptance. Keep unknown results unresolved and preserve read-only
   observation when a write path is disabled.

## Reproducible fixtures

The deterministic tests exercise a real WKWebView DOM as well as injected
executor races. They are not Safari/Chrome or desktop permission acceptance.

```sh
swift test --filter 'Ask(BrowserDOM|BrowserExecutor|ComputerExecutor|ComputerTargetProbe|ObservationStore|AutomationScriptRunner)Tests'
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
