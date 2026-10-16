# GUL-399: workflow image results

This increment is stacked on #530 (`agent/arch-gpt-astra/gul-399-context-images`). The approved issue remains in progress. A workflow has already executed before image inspection begins; this change never re-executes its producer.

## Behavior and ownership

- `AskWorkflowImage.resolve` is now asynchronous. A two-slot admission gate precedes detached filesystem/base64 work. ImageIO inspection and PNG/TIFF clipboard conversion run in the existing independent media executable, through the existing two-child, three-second preview domain and confirmed-retirement leases. No new executable, packaging path, or deployment target is introduced.
- Two allowlisted operations carry version/UUID-checked metadata. Supported types are PNG, JPEG, GIF, WebP, TIFF and HEIC. Inspection considers the first complete frame, with at most 100 million source pixels and 100,000 pixels on either axis. The existing DPI convention remains: at least 144 DPI means half-size points. Display uses the existing validated, at-most-1600-edge RGBA preview; the host never parses the original encoding.
- Inputs are at most 20 MiB, including file paths (previously only data-URL input had this bound). The encoded stdout envelope is at most 40 MiB. Original script stdout/copy actions and source-file references survive projection failure. A data URL's displayed failure text stays clipped while its text-copy action retains the full value. Missing files, invalid images and decoder unavailability remain distinct outcomes.
- Data-URL cache files use the content digest and the child-validated extension. The private, descriptor-relative cache refuses corrupt existing entries rather than overwriting them. It is limited to 128 entries / 256 MiB, with no automatic eviction. Existing nonprivate legacy cache directories are conservatively refused; this increment does not chmod, remove or recreate them. Source file paths stay revealable, and hashes reject changed contents before display/copy; paths or modification timestamps are not validation proof.
- Workflow result cards and editor previews own asynchronous preparation. The result view uses the existing bounded scope observers and 64 MiB bitmap budget. A full `AskPluginImage` identity (including the digest) replaces the app-lifetime URL/date image cache. Editor run identity, view disappearance, session replacement and access invalidation reject late results and release pixels. The editor scope is local to the explicit workflow editor and does not require cloud login.
- Clipboard preparation generates first-frame PNG and TIFF in the helper, applies EXIF orientation, and preserves the 72/144-DPI point convention. Copy is limited to 8192 axes / 16,777,216 pixels and 80 MiB combined output. Two retained 80 MiB reservations bound owned clipboard results. Fixed output filenames are read relative to the private directory; sizes, signatures and no-follow reads are checked before pasteboard publication. The original file URL is included, as before; it remains a reference to a user-owned mutable file.
- The composer intercepts image-copy actions and owns one preparation task. It rechecks the original access scope, session, current plan, result generation and image identity immediately before a single pasteboard write. Duplicate clicks do not queue work. Cancellation or failed preparation leaves the produced result available. Successful copy alone finishes/dismisses the result. No producer, write-back or workflow action is replayed.

## Validation

Implementation and caller/ownership self-review preceded the focused run. No full suite, live workflow side effect, network provider, screenshot capture, microphone/TCC or release-signing exercise was performed. All media inputs were synthetic; crash/hang children were harmless local fixtures.

Direct instrumented builds used `scripts/test_runtime.child_environment()`:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
```

The test bundle and helper contained `__llvm_covmap` and `__llvm_prf_cnts`. No discovery rebuild was inserted. The focused command was:

```sh
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<scope below>'
```

Scope (34 distinct methods):

- `WorkflowImageIsolationTests`: 13 new methods covering real helper inspection/render/copy, PNG/JPEG/GIF/TIFF/HEIC formats, DPI/orientation, malformed/truncated/device/oversized input, corrupt/capacity cache, fixed-file output refusal, same-path content changes, retained cancellation admission, producer-once semantics, failed/duplicate/revoked/stale clipboard publication, editor lifetime and actual view pixels/clearing.
- `AskWorkflowImageTests`: four existing image path/data-URL/sizing/clipboard methods, migrated to async preparation.
- `AskWorkflowO4PluginTests`: nine existing image/text/follow-up/permission methods after the plugin finish path became async.
- `AskWorkflowDeveloperToolsTests`: the backtick-named QR image method; `AskWorkflowAuthoringTests.realRunsKeepPreviewAssetsAndNeverPublishTestWrites`.
- `MediaPreviewTests`: protocol bounds, raw raster validation, crash/hang, retained files/reaping (four methods). `MediaWorkerTests`: cancellation and retained-child shutdown admission (two methods).

Initial run: 32/34 passed. Two assertions compared `/var/...` to its canonical `/private/var/...` alias, one in the injected post-execution resolver fixture and one in the existing data-URL cache test. Both were corrected to compare resolved paths, with no production change. The two failed methods passed on the targeted retry (one XCTest and one Swift Testing). No production changes or timeout changes were made after the initial run. Two packaging tests and an actual copied/bundled-helper PNG/TIFF probe also passed.

The screenshot `workflow-images.png` was inspected. It shows the actual raw-pixel workflow component in a synthetic hosting window. Tests also exercised editor preparation and clearing after scope invalidation. This is not evidence of a complete interactive launcher/editor flow.

Changed executable-line coverage: **238/254 (93.70%)**. `workflow-images-coverage.json` records every changed production file. Coverage comes from the saved initial production-final binary/profile set; subsequent edits changed only the two path assertions. Seven matching profiles (three host, three direct helper, one bundled-helper probe) were individually validated and merged without warnings. The helper is an `llvm-cov --object`, so helper-only code is counted. No previous-increment profiles or changed-counter-layout profiles are merged. The retry's profiles were also individually validated and remain separate validation evidence; they are not merged into coverage because test counter layouts changed.

The 16 uncovered lines are composer dispatch (four), default clipboard-preparation bridge (three), account-invalidation bridge (one), result-card bridge (one), editor parent branches (six), and the defensive attachment-decoder rejection of workflow operations (one). Core 94/94 and child 42/42 line hits do not prove every branch, native allocation, supported codec variant or watchdog path. WebP's allowlist/extension is checked, but no actual WebP image fixture was decoded.

### Commands, timings and binary identity

Task-local wrappers `gul-399-supervisor-build.py` and `gul-399-workflow-image-test.py` use the sanitized child environment. The exact initial filter was:

```text
^Typeflux(?:Focused)?Tests[./](?:(?:WorkflowImageIsolationTests|AskWorkflowImageTests|AskWorkflowO4PluginTests)[./]|AskWorkflowDeveloperToolsTests[./]`qr result is displayed as an image and decodes to the original text`|AskWorkflowAuthoringTests[./]realRunsKeepPreviewAssetsAndNeverPublishTestWrites|MediaPreviewTests[./](?:testRejectsUnboundedOptionsAndMixedProtocols|testRasterDimensionsStrideAndPageIdentityAreValidatedBeforeAllocation|testPreviewCrashAndHangReturnWithoutReplaying|testRetainedPreviewFilesAndSlotsWaitForActualReaping)|MediaWorkerTests[./](?:testTwoRetainedChildrenBoundAdmissionAndShutdownFences|testCancellationBeforeAndAfterDispatchRejectsLateResult))
```

The retry filter selected only `WorkflowImageIsolationTests.testPostExecutionFailurePreservesFullOutputWithoutProducerReplay` and the literal backtick-named `AskWorkflowO4PluginTests` method `a data URL image lands in the cache`.

| Command | Wall time |
| --- | ---: |
| Preparation build 1 | 274.11 s |
| Preparation build 2 | 58.78 s |
| Production-final build 3 | 70.18 s |
| Initial focused run | 55.10 s |
| Test-only assertion rebuild | 45.77 s |
| Two-method retry | 34.65 s |
| Two packaging tests | 0.177 s |
| Copied-helper probe | 0.146 s |

Total tracked build/test/probe time: **538.91 s**, plus coverage extraction and visual inspection. All four builds passed; there were no compilation failures. The 34-method first pass had exactly two path-alias assertion failures described above.

- Production-final XCTest SHA-256: `92b610c4a08091025ae48d74b24c2e77ff8fa0470634908e9765855e4d296999`.
- Helper SHA-256 (unchanged by the test-only rebuild): `81cc8f44462c1448f50b8af738ff26bf77dd1085b31e9f6742b2b81b5596785c`.
- Retry XCTest SHA-256: `cc6feef0ad5825625672660cad3c34ab538c58037aceb562102c4a7b1e5dd09b`.
- Matching coverage binaries/profiles were saved in `.build/workflow-image-validation/initial`; each raw profile passed `llvm-profdata show` before a warning-free sparse merge. `llvm-cov show` used the saved test binary plus the identical helper as an additional object. The committed report measures only added executable production lines relative to #530.
- App and helper minimum OS remain macOS 13. The XCTest runner has a macOS 14 minimum from the existing Swift Testing toolchain; this run does not validate macOS 13 hardware. App has zero media-runtime module symbols; native decoding stays in the helper.

## Remaining boundaries

`AskPluginItemIcon.image` still parses custom icon URLs with `NSImage(contentsOf:)` and caches them by path. Browser favicon and Finder-icon paths remain host native boundaries; they are separate from the workflow main-result path completed here. Existing file-index/semantic decoder workers are unchanged.

Host file reading/copying/hashing/base64, raw bitmap construction, pasteboard writes, UI and filesystem calls remain in process. Admission and pixel reservations bound owned work, not arbitrary native/AppKit/GPU allocation, filesystem stalls, system-wide OOM, or power-failure durability. A host crash can leave private temporary files. Copy can refuse a source which was inspectable but exceeds its smaller full-resolution conversion budget; the source and reveal action remain available. GIF/TIFF copies are first-frame static representations, not animation/multipage export.

Stage-2 adapters and condition-driven/persisted health integration, remaining media boundaries, and audio/TCC/signing/performance verification before any microphone-capture isolation decision remain required. Real CoreML performance, full Xcode application build, Developer ID/notarization, Intel/macOS 13 hardware and actual AppKit quit/recording integration remain unverified. This PR is not whole-issue acceptance.
