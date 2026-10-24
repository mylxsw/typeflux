# Chat idle CPU: sample-driven correction — 2026-10-24

## Evidence and causal path

The user identified PID 85910 as the `chat` owner, using 20.2% CPU while voice and background owners were at 0.0%. Its supplied process sample contains 756 main-thread observations, including 305 inside `AppIconController.apply`, reached from the application-icon notification observer. Those frames include `NSApplication._setApplicationIconImage`, `AppIconController.roundedTile` and `CGContextDrawImage`. This is a sampled hotspot, not a claim that 305/756 equals CPU utilization. The same sample shows SwiftUI layout/rendering and repeated `SettingsStore` construction from `AskModelLibrary.settings`. The RPC reader is blocked waiting for input, so its large sample count is not evidence of a socket spin.

The supervisor broadcasts committed defaults changes. Defaults also store runtime application-use rankings and window positions. Previously, every receiver unconditionally reapplied appearance and broadcast all presentation/audio/persona preference notifications. An unrelated preference update could therefore redraw a 1024-pixel application icon and invalidate the chat/overlay interface. Repeated delivery repeated that work even if the selected icon never changed.

## Corrections

- Track each receiver's prior defaults snapshot. Emit presentation/audio/persona/ring notifications only when their corresponding keys change, including deletion/reset. Advance the snapshot before callbacks run. The tracker is initialized before installing process preference synchronization.
- Apply language and appearance only when their actual stored preferences change. Unrelated app-use/window bookkeeping produces no presentation effects.
- Retain only the selected application icon and its style. Repeated application is a no-op; a failed load preserves the last valid selection and remains retryable. Dock reappearance can explicitly reinstall the retained icon after activation-policy changes, without decoding another copy. Selecting the bundled glass icon still clears a custom icon.
- Reuse the model library's already-created `SettingsStore`. Values remain live reads from the same defaults; rendering a model menu no longer repeats constructor migrations.
- Validation exposed a separate appearance-layout regression: four voice-style cards forced a wide single row. Use adaptive columns, and include all four cards in the existing multilingual bounds checks. The raw-view test canvas also needs enough height to instantiate the expanded lazy icon grid; this does not change the scrollable product page or relax its width assertions.

Shared defaults storage, account routing, model-selection values, microphone preparation and the selected speech model's retention policy are unchanged. No application usage data, private conversation text, sample attachment or raw runtime paths are committed.

## Focused validation

```bash
make coverage SUITE="FeaturePreferenceChangesTests AppearanceSettingsTests DockVisibilityControllerTests AskModelLibraryTests FeatureShortcutOwnerTests FeatureBackgroundRuntimeTests FeatureProcessConsolidationTests"
```

The new fixture checks unrelated usage/window writes, each affected notification and reset, coalesced related-key changes, 1,000 repeated icon applications, forced Dock reinstall, failed artwork loading/retry and live model preferences. Existing callers cover actual icon artwork/settings rendering, activation-policy transitions, model-library persistence, shortcut binding refresh and isolated-owner contracts. Fixtures use temporary defaults, synthetic icon installers and native test views; they do not launch a development app or feature child.

**42 distinct relevant tests ultimately passed.** The initial scope ran 8 XCTest and 34 Swift Testing tests: 40 passed, while two appearance UI tests failed. These revealed actual card overflow plus missing lazy-grid controls in the old fixed-height canvas. Only those failed methods were retried while resolving the issues; the other passing suites were not repeated.

| Validation | Complete command wall time | Result |
| --- | --- | --- |
| Initial focused scope | 245.32 s, including 234.22 s build/discovery | 40 passed; 2 UI failures |
| Isolated reproduction of the two failures | 37.46 s | Both reproduced |
| Readiness-only attempt | 238.56 s, including a rebuild after the concurrent side-panel commit | Both still failed; waiting alone was insufficient |
| Synthetic AX/layout capture | 82.21 s | Identified clipped icon rows and fixed-row overflow |
| Adaptive wrapping and enlarged icon-choice canvas | 80.62 s | Selection/persistence passed; remaining layout canvas still needed its height corrected |
| Final single-method retry across all locales, widths and themes | 109.48 s, including 88.34 s build/discovery | Passed |

One attempted method filter matched no tests and stopped in 33.80 s; it was corrected without falling back to a full suite. One build stopped in 31.16 s because another task modified a side-panel test source during compilation; no tests ran in that attempt. The concurrent side-panel commit is preserved. These attempts are not represented as passing validation.

Final changed executable-line coverage is **46/56 = 82.14%**, above the current 60% target. Matching binary/profile/LCOV snapshots were retained outside the repository. Unchanged CPU-fix source uses the initial scope's counts; the modified voice-style layout uses only final-source counts. The failing appearance attempts are explicitly recorded above; all original 42 methods have a successful final execution. Native coordinator startup remains a manual acceptance boundary.

Actual post-fix idle CPU and rendering behavior on the user's running Mac require local acceptance; no measured CPU reduction is claimed from unit tests.

## Local acceptance

After updating and restarting, open chat with a static conversation and leave it untouched for at least two minutes. Compare the chat PID's CPU with the supplied sample. Switch to another application without changing Typeflux preferences; the chat must not repeatedly redraw its icon or interface. Change icon/theme/language deliberately, and hide/show Dock-owning windows; each intended change must remain visible. If CPU remains high, sample the new chat PID again to identify the remaining hotspot rather than assuming a second cause.

The failed-method retries used the normal coverage runner, for example:

```bash
make coverage FILTER='AppearanceSettingsTests/.(rendered|all)'
make coverage FILTER='AppearanceSettingsTests/.all languages fit'
```
