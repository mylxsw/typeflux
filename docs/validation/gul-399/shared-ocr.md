# GUL-399: shared screenshot OCR isolation

This increment was implemented on #542 (561f9694). At delivery #542 had merged into `agent/arch-gpt-astra/gul-399-source-app-icons` at 834d7e04, whose tree is identical to 561f9694; the incremental PR targets that actual landing branch. Main c90e3822 contains #535 but not #536–#542. A separate integration entry will preserve the concurrent main changes and land the remaining chain. It migrates shared screenshot, translation and sensitive-information OCR; the previously delivered clipboard file-to-text path remains separate. The overall issue remains in progress.

## Behavior and bounds

`VisionImageTextRecognizer` is now an asynchronous facade over the existing media executable. ImageIO and Vision recognition run in `MediaTextDecoder`, with accurate recognition, language correction and automatic language detection. The host supplies bounded encoded files or raw RGBA; it retains no Vision candidates or range-box closures. No new executable, packaging target, provider request, screen capture or automatic operation replay is introduced.

Two admissions are acquired before detached work and retained until it actually finishes. A dedicated two-child, 30-second pool uses the existing 35-second helper alarm and confirmed-reaping input leases. File inputs are local regular resident files up to 10 MiB, with pre/post device/inode/size/mtime/ctime checks. Raw inputs are at most 16,384 pixels per axis and 16,000,000 pixels (64 MiB framing cap). The host rasterizes already-owned CGImages within those bounds. Requests are at most 1 KiB; responses at most 2 MiB. Results allow 1,024 lines, 16 KiB per line and 256 KiB total text, finite confidence/normalized positive boxes, 128 exact regions per line and 4,096 per response. Mixed responses, invalid identities, overflow ranges, split UTF-16 surrogate pairs and invalid geometry fail closed.

The existing sensitive-text rules now live in the shared protocol module. While native candidates are alive, the child calculates exact Vision boxes only for the actual phone/email/card/ID/credit-code/address matches. This is a bounded linear list of requested matches, not an all-substring table. Host `RangeLocator` synchronously looks up those exact ranges, with no IPC or native parsing. Other ranges are explicitly unavailable. Production redaction never substitutes proportional geometry when a required native box is missing: recognition fails. Legacy/injected lines retain their existing detector contract. UTF-16 identity, confidence, reading order, orientation and top-left coordinates survive serialization and tiling.

Tall-image recognition retains overlapping-band order/merge behavior, with two overall admissions, at most 32 bands, 64 million pixels/16,384 width/65,536 height for the original, and 4,096 lines/1 MiB accumulated text. Every band still obeys the 16-million-pixel worker bound; oversized bands fail rather than silently downscale. Cancellation is checked between bands and after awaits.

Launcher replacement/reset/account invalidation/owner release cancel original recognition; the plugin checks source identity again after awaiting. Translation owns its task and clears screenshot text/pixels on actual panel orderOut or account change. Redaction controllers retire work and clear their panel on cancellation/account change. Failed recognition now has a distinct localized five-language panel state, not a successful empty scan; it advises manual privacy review, with Cover all disabled. No recapture, translation, Agent operation or pasteboard write is retried as failure recovery.

## Validation

Implementation and self-review preceded focused validation. No full suite was run. Commands used `scripts/test_runtime.child_environment()`:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
# Verified __llvm_covmap and __llvm_prf_cnts in host test binary and media helper.
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<scope below>'
python3 -m unittest scripts.tests.test_media_packaging
```

No discovery rebuild was inserted. Final scope: 54 distinct methods (45 XCTest + 9 Swift Testing): 10 SharedOCRIsolation, 7 ImageTextRecognizer, 15 ScreenshotSensitiveInfo, 4 ScreenshotRedactionSuggestions, 5 ImageTiling, 2 MediaProtocol, 2 MediaWorker, 7 AskScreenshotFollowUp, 2 AskTranslationPanelCoordinator. Exact filter:

```text
'^Typeflux(?:Focused)?Tests[./](?:SharedOCRIsolationTests[./]|ImageTextRecognizerTests[./]|ScreenshotSensitiveInfoTests[./]|ScreenshotRedactionSuggestionsTests[./](?:testThePanelShowsOnlyFinishedVisibleFindingsUntilClosed|testTheControllerScansOnceAndEditsTheDocumentThroughItsHost|testAControllerWithoutAScannerOrCancelledFindsNothing|testTheVisionScannerReadsThenDetects)|ImageTilingTests[./](?:testTheTiledRecognizer|testExactBoundsFollowTheLineOntoTheWholeImage|testLinesInTheOverlapAreKeptOnceAndPlacedOnTheWholeImage)|AskTranslationPanelCoordinatorTests[./]`(?:screenshots recognize locally then translate or show recoverable errors|pending selection and OCR do not overwrite A newer entry or user edits)`|AskScreenshotFollowUpTests[./](?:recognizedTextOpensInTheLauncherAfterItsContext|aStaleLauncherOpeningDoesNothing|translatingRunsTheTranslationKeywordOnTheText|nothingToTranslateLeavesTheEmptyCard|theWaitingScreenshotsTextIsTheResultWithItsKeys|aRunForAnotherScreenshotStops|noTextShowsTheEmptyStateWithItsWaysOn)|MediaWorkerTests[./](?:testRealHelperImagePDFMalformedAndCrashHangFixtures|testShutdownCancelsRunningChildAndRejectsNewWork)|MediaProtocolTests[./](?:testInvalidIdentityVersionAndAmbiguousResponsesFailClosed|testJPEGEnvelopeRejectsMixedWrongTypeBrokenBase64AndPageOrdering))'
```

Synthetic private inputs/injected engines cover exact Unicode geometry, source changes, malformed/truncated/oversized data, cancellation with retained admission, duplicate capacity refusal, worker crash/hang/shutdown, source replacement, account revocation and actual panel hiding. A real helper reads synthetic email text and its exact box is compared with a native fixture reference. File and raw input agree; existing top-left and overlapping-band tests pass. The actual redaction failure panel screenshot was inspected (`shared-ocr.png`), including after revocation cleanup. No real user capture, clipboard writes/paste events, network/provider, microphone/TCC or workflow side effects were exercised.

Preparation build 1 failed after 346.35 s on a new test's ambiguous `.nan`; fixed to `CGFloat.nan`. Build 2 passed in 91.19 s. Initial focused pass took 55.44 s: 53/54 methods passed, with one real protocol failure accepting a split UTF-16 surrogate range. Added explicit code-unit boundary checks and removed the misleading successful-scan footer from the failed panel. Correction build passed in 51.89 s; the complete mapped scope then passed 54/54 in 22.18 s. Packaging passed 2/2 (2.917 s command wall time). The actual copied app-bundle helper blank-PNG recognition probe passed in 1.214 s. Tracked build/test/packaging/probe total: 571.181 s, excluding audit, screenshot inspection and coverage extraction. No further functional retries.

Changed executable lines: **335/343 = 97.67%** (`shared-ocr-coverage.json`). All evidence uses nine fresh profiles from the final correction binary only: three host, five directly invoked helper, one copied helper. Each raw profile was individually validated; sparse merge completed without warnings. The initial failed-pass profiles are excluded. New Sources were included via `git add -N`; helper code was counted with llvm-cov `--object`. An early read of the still-running extraction's output found an empty JSON file; after collecting extraction completion it parsed successfully, with no profile omitted or test reclassified.

Matching evidence is retained in `.build/shared-ocr-validation/final`. SHA-256:

- XCTest: `c7e39fc559c8068b67bccbc2bf74d1ee879d7d9f3a275616c428806b9e0770f0`
- Helper: `87bb014e57bacbc5176e57d9c243e416fe305578b07cc57fc6f97494a19ad090`

Eight uncovered lines: four DI/quit bridges, panel close override (actual orderOut covered), legacy detector forwarding method, and two NSDataDetector address/default branches. Decoder 69/69 and protocol geometry 43/43 line hits do not prove every native branch/allocation/language/format/watchdog behavior. `nm -gU` found zero media-runtime symbols in host and 77 in helper. App/helper Mach-O minOS remains 13.0; this is not macOS 13/Intel hardware validation.

## Remaining boundaries

`ScreenshotTextHeightMeasuring` still invokes Vision text-rectangle detection synchronously for mosaic sizing/text-only masks; `VisionScrollOffsetEstimator` still performs native translational registration. These are separate from OCR and must be migrated without blocking getters or weakening redaction safety. Clipboard AVPlayer playback and user-requested OS Quick Look remain separate native/UI boundaries. Existing file-index/semantic worker paths are not duplicated.

The shared OCR admission limits do not bound all capture/AppKit/GPU/system allocations. Host raw rasterization, filesystem calls, source snapshots, JSON/base64, pasteboard, SQLite/import-export and UI remain in process; metadata checks are not immutable filesystem transactions. Health/settings integration and other stage-2 adapters remain, as do audio/TCC/signing/performance verification before deciding microphone capture ownership. Real CoreML/model performance, full Xcode build, Developer ID/notarization, real quit/recording and macOS 13/Intel hardware remain unverified. No arbitrary host crash, system-wide OOM or power-loss durability guarantee is made.
