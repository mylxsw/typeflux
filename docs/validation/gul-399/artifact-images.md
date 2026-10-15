# GUL-399: stored artifact image presentation

Stacked on #524 (`1148a8c2`). This slice isolates the thumbnail, image preview and copy validation of already saved artifacts. It does not complete typed tool-result projection or generated-response validation, and does not complete GUL-399.

## Boundary and ownership

`AskStoredArtifactCard` and `AskArtifactPreviewView` no longer parse original images through ImageIO or `NSImage(data:)`. Their view-owned `AskArtifactImageModel` asynchronously requests raw pixels from the existing media helper. The host builds an `NSImage` from a validated RGBA `CGImage`; original encoded bytes never enter a host decoder in these paths. PNG/JPEG/GIF declarations are checked against ImageIO's actual type inside the child; the response must acknowledge the requested type, so an older helper that ignores the new field fails closed. Unsupported or mislabeled inputs fail without disclosing native errors, child output or private paths.

The existing preview pool owns two children, a three-second process deadline, failure budget and confirmed-reaping file leases. A separate two-slot admission counter bounds retained input and detached work **before** dispatch into that pool; there is no conversion queue or new worker. Inputs retain the artifact store's 16 MiB ceiling. Preview pixels retain a 1600-pixel long edge and existing raw-raster bounds; source limits remain 100 megapixels/100,000 per axis. Neither these limits nor a process deadline promises to bound every native allocation or host filesystem syscall.

Loads validate reference identity, content hash and access. After the await, generation, cancellation and access are checked again before display or clipboard mutation. Permission denial/expiry clears cached pixels. Copy refuses a duplicate in-flight action, reopens the saved artifact and validates it, then writes its original PNG/JPEG/GIF data to the pasteboard without decoding it in the app. This preserves full resolution and original encoded metadata/animation; the displayed thumbnail is not substituted for the original. The system or a receiving application may decode that clipboard representation later. The view cancels copying and decoding work on disappearance or reference replacement. Old completion cannot overwrite a new selection.

The producing tool, paid generation and durable receipt are never invoked by this code. A decode/presentation failure keeps the saved artifact and its export path. It does not delete/recreate a database, repeat a tool, or automatically retry a conversion. Existing media-pool startup/quit fencing applies; no new executable, signing asset or packaging path is introduced.

## Audit and next boundaries

The initial audit also covered `AskTypedContent`, `AskLocalTools.jpegDataURL`, `AskCodeSandbox.firstImage`, `MCPToolAdapter`, `AskToolResultRequest.legacyProjection/forPeer/message`, `AskLocalPrompt`, and `AskGeneratedImageData`/`AskImageGenerationService`.

- Typed content currently calls ImageIO from synchronous projection used by receipts, network delivery, local prompt construction and computed history properties. Replacing it with synchronous process IPC would block those callers. Its coherent async preparation/projection migration remains required; native inspection and legacy JPEG conversion are still in the host there.
- Code-sandbox output JPEG conversion remains a host path; the producing program must never be rerun to repair image presentation.
- Generated response validation still loads ImageIO before a saved artifact exists. A later migration must preserve successful paid output when validation is unavailable, without retrying generation. This PR only covers artifacts that have already been saved.
- Other encoded-image/message display, screenshot encoding, filesystem load/hash/export, SQLite/JSON and UI remain in-process boundaries. The artifact store load and hash are still synchronous; the native image decoder and child waiting are asynchronous.
- Persisted health/settings integration for media/native/inference and other stage-2 adapters remain. Audio/TCC/signing/performance verification must precede a microphone isolation decision. Real CoreML, full Xcode/release signing/notarization, Intel/macOS 13 hardware and actual app quit/recording interactions remain unverified.

## Validation

Self-review covered decoder placement, the two admission limits, file lifetime, response identity/type, cancellation/generation fencing, access revalidation, clipboard representation and absence of producing-tool callbacks.

The first focused pass executed **37 XCTest methods**, with 36 passing and one UI-fixture failure. The fixture destroyed its hosting view between state screenshots; the view correctly cleared its model on disappearance, invalidating the fixture's expectation. Keeping the host alive fixed the test with **no production change**. Its isolated retry passed. A final screenshot-fixture adjustment supplied window appearance/background; the same isolated method passed again. No full suite, paid generation, remote provider request, microphone/TCC interaction or hardware toggle was performed.

Scope and mapping:

- `AskArtifactImageTests` (12 methods): native PNG/JPEG/GIF MIME checks, malformed/mislabeled/oversized data, raw-pixel results, two-task admission and cancellation, private pasteboard formats, post-await access revocation, stale generations, duplicate copy, preserved originals, safe errors and UI states.
- `AskArtifactToolTests` (6): directly affected artifact UI/presentation callers plus artifact creation/approval, store reopen, receipt preservation and selected-session access.
- `MediaPreviewTests` (11): shared extraction, bounds, file ownership/reaping, helper crash/hang, cancellation and image/PDF compatibility.
- `MediaProtocolTests` (7): unchanged attachment contracts and shared protocol validation.
- `MediaAVPreviewTests/testTimingAndWaveformProtocolRejectsNonfiniteWrongIdentityAndMixedPayloads` (1): AV compatibility after adding optional image type metadata.

Commands used `scripts/test_runtime.py`'s sanitized `child_environment()`:

```text
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
xcrun otool -l <test-binary>  # verified __llvm_covmap and __llvm_prf_cnts
xcrun otool -l <media-helper> # same
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter <scope>
python3 -m unittest scripts/tests/test_media_packaging.py
```

Full focused filter (not the full repository suite):

```text
^Typeflux(?:Focused)?Tests[./](?:AskArtifactImageTests|AskArtifactToolTests|MediaPreviewTests|MediaProtocolTests)[./]|^Typeflux(?:Focused)?Tests[./]MediaAVPreviewTests[./]testTimingAndWaveformProtocolRejectsNonfiniteWrongIdentityAndMixedPayloads
```

UI retry filter:

```text
^Typeflux(?:Focused)?Tests[./]AskArtifactImageTests[./]testPreviewAndCardRenderLoadingReadyAndUnavailableStates
```

Both packaging tests passed (0.147 s). A synthetic PNG through the helper actually copied to `Fixture.app/Contents/Helpers` passed the MIME-checked raw RGBA probe (0.143 s). The helper Mach-O reports minimum macOS 13.0. These are synthetic fixtures, not a hardware/performance or signed-release benchmark.

Changed executable-line coverage: **121/126 = 96.03%**. The report includes the helper with `llvm-cov --object`; all eight input profiles individually validated before merging, with no warnings. They come from the single production-final build used by the initial focused pass and probe: three host and five helper profiles. The matching binaries and merged profile were saved before changing the UI test fixture. **No production source changed after that pass**; neither later test-build profile is merged into this report. This conservative attribution leaves the ready-state view line uncovered in the report even though the corrected UI method exercises it. Other uncovered lines are one default decoder bridge and the three copy-button task bridge lines. Line coverage does not establish every native allocation failure, signal/alarm branch or a physical clipboard destination's behavior.

Measured binary/profile SHA-256:

```text
test binary c2617a1c4c4623ce4fd36b99ba3e09ceb2db89b9713fb9111adac0a1a0f5dd1f
media helper 8f34cabc20b05c07d52a3ba5a201e0becd799a8f0ad9e5e2a8852a662c43c817
profile 0ae65cc6305599067cb866076d64164f6f83dfee2f1df4ed5f224d8582b7749c
```

Measured command wall times, including preparation and runner startup:

| Command | Seconds | Result |
| --- | ---: | --- |
| Initial direct instrumented build | 211.73 | Passed |
| Lifecycle/UI fixture preparation build | 11.18 | Compile failure: main-actor default argument |
| Corrected preparation build | 204.51 | Passed |
| Type acknowledgement/clipboard preparation build | 11.77 | Compile failure: main-actor default closure |
| Production-final instrumented build | 70.62 | Passed |
| Initial 37-method focused pass | 16.59 | 36 passed; one fixture lifecycle failure |
| UI fixture correction build | 34.53 | Passed; no production edit |
| Isolated UI method retry | 7.78 | Passed |
| Screenshot appearance fixture build | 39.45 | Passed; no production edit |
| Isolated UI method/screenshot export | 8.50 | Passed |
| Two packaging tests | 0.147 | Passed |
| Copied-helper probe | 0.143 | Passed |

Total measured build/test/probe command time: **616.95 s**. Coverage postprocessing and code review are not included in that timing. Both actor-isolation compile errors were fixed before the first functional pass. No test-discovery rebuild was inserted between instrumented builds and prebuilt tests.

`artifact-image-loading.png`, `artifact-image-ready.png` and `artifact-image-unavailable.png` are synthetic view fixtures. Ready/unavailable screenshots were visually inspected after giving the host a dark window appearance and background; this corrects the transparency of a detached snapshot, not production UI. The fixture uses injected pixels and a synthetic one-byte artifact, separate from the real-helper PNG tests. It does not represent a manually exercised application window, real clipboard recipient or signed release.
