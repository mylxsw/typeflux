# Model settings scroll investigation (2026-09-29)

The reported mouse-wheel stutter is **not yet reproduced or resolved**. Previous
wheel tests checked movement and stable document height; they did not establish
smooth presentation on the user's running application.

## Confirmed regression

The unified model page omitted the legacy settings page's free-provider filter.
Both speech and language configuration lists now hide the bundled Free Model
provider when its source catalog is empty. This is a presentation filter: stored
provider/model references, Cloud availability and local fallback are unchanged.

## Measurements

Measured on the native macOS test host using the actual `StudioView` and isolated
fixture settings, based on main `ce5fbc3`. No production account or credentials
are used. The no-sampler runs include the free-provider visibility correction.
Each run sends 600 line-wheel events, reversing direction every 60 events, with
16 ms sleeps between events. The timed block includes synthetic event creation,
`scrollWheel`, synchronous layout and display. It is **not** an FPS or input-to-
screen latency measurement; asynchronous display work is outside that block.

| Surface, without external sampler | Median | p95 | Maximum |
| --- | ---: | ---: | ---: |
| Provider configuration list | 0.517 ms | 2.363 ms | 3.118 ms |
| Provider detail with 303 models | 0.655 ms | 2.184 ms | 3.644 ms |

Two earlier runs with `sample` attached showed isolated 1.8–1.9 second stalls;
the instrumented breakdown placed the second stall in synchronous layout.
These stalls did not recur without the external sampler. They are therefore
not sufficient evidence of the reported production bug. Most sampled main-thread
stacks were the idle run loop, not provider lookup or credential reads.

## What this does and does not establish

- Both tested surfaces have one vertical scroll owner, move on wheel input,
  and keep their document height stable.
- The large-catalog case prevents relying solely on a three-model fixture.
- There is no evidence here to justify another speculative eager/lazy layout
  swap or to identify credential access as the remaining cause.
- The host uses a borderless test window, bypasses application event routing,
  disables live catalog loading, and uses a logged-out fixture. Production
  window composition, account refreshes, device-specific event delivery and
  other running app activity remain unmeasured. Smoothness on the user's
  machine cannot be inferred from these results.

The next useful evidence is a short recording showing the affected surface and
the running app version/build. Reproduce that exact surface/window configuration
and collect an application trace while the visible hitch occurs before choosing
a performance fix. A recording must avoid API keys or other private settings.

## Reproduction

From the repository root:

```sh
TYPEFLUX_ASK_SNAPSHOTS="$PWD/scroll-artifacts" \
TYPEFLUX_SCROLL_PROFILE="$PWD/scroll-artifacts/scroll" \
swift test --filter AskConversationVisualTests.renderModelSelectionSurfaces
```

For the large provider detail, also set `TYPEFLUX_SCROLL_LARGE_CATALOG=1` and
`TYPEFLUX_SCROLL_SURFACE=models-provider-dark.png`. Output includes fixture PNGs,
a CSV with per-event wheel/layout/display durations, a summary and a process ID
marker for optional external sampling. The measurement is opt-in and has no
wall-clock threshold in CI. Compare runs without an external sampler first.
