# Generated response batch authority

Validated base: main `11f8f783bc8890c786436f3ad62581cc01a2ec42`, including the concurrent #587 GUL-404 source layout. This focused validation does not establish GUL-404's indexing behavior.

## Behavior and review

The default AskImageGenerationService validator now binds one immutable native authorization at generate entry, before request construction or transport. All images from that invocation use the same stamp across response parsing, downloads and validation. A later image cannot adopt a recovered generation. A fresh explicit invocation captures current availability.

AskGeneratedImageValidator.batch returns a concrete bound validation closure using the existing explicit-authorization overload. The service's optional custom validate override retains its own contract and never acquires an imposed native-health dependency. The nativeValidator constructor dependency defaults to the same shared preview validator; tests supply a managed worker with an injected runner. Existing memberwise transport/validate callers compile unchanged. No generic dispatcher, pool, scheduling hook, full DI, global bypass, helper change or new grant.

Native availability is not consent to POST. An initially unavailable native lane does not block an already-authorized generation request. Response retention still precedes cancellation, parsing, downloads and decoder failures. Already validated partial images, usage, request identity and bounded unvalidated originals remain available; loss of native availability does not erase completed output. Subsequent validation refuses under the original stamp. The publishing caller retains its existing Task/account/project checks. There is no paid-request retry, response resubmission, additional download, write retry, deletion or overwrite for recovery. The existing same-URL idempotent GET retry policy is unchanged.

Self-review before functional tests traced generate/request/download, retention writes, default and custom validator callers, and AskLocalTools+ImageGeneration publication. Existing facade/native slots, private input copies, FD/child/host leases and cancellation collection remain unchanged. No input is replayed by readiness. Authorization begins at service entry, not earlier UI scheduling or provider consent. Already-entered effects cannot be rolled back; this is not a filesystem/settings/permission transaction.

This increment completes the generation-response outer batch only. Default AskTypedContent output/prepare/prepareHistory and AskCodeSandbox.firstImage outer loops still require batch integration. Their per-facade authorization prerequisite is already on main. Custom injected validators and standalone workers retain their lifecycle responsibility.

## Focused validation

Using scripts/test_runtime.child_environment:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit inventory in generated-batch-authority-methods.json>'
```

Prebuilt native_tools/native_environment/swiftpm-testing-helper inventory, not XCTest as a program. **29/29 distinct methods passed on the first functional run:**18 XCTest methods across four suites (0.153s execution),11 Swift Testing methods across two suites (0.186s). Five new methods establish:

- The first image has actually returned from native validation (activeCount zero) before a held second private download. Disable/start then rejects the second validation without another native call. The first validated image, both downloaded originals, usage/request ID and one POST receipt survive; a fresh explicit batch succeeds.
- A pre-ready batch waits in a fake response transport while the lane becomes ready. Neither image adopts readiness, both originals and the charged response remain, and a fresh invocation succeeds. No readiness callback performs work.
- Cancellation during an entered uncooperative injected validation retains native occupancy and the response until physical return; the late image is unvalidated and usage survives. The held fixture is released and its task joined.
- A custom validator remains independent of an unready native lane and preserves a mixed success/failure partial result.
- A transient fake download failure retries only the same GET, with one POST and the existing validation/output behavior.

Existing selected methods cover direct facade stamps and retirement, private receipt identity/budgets, failed download/retention, protocol limits and independent preview health. Every selected body was reviewed; methods using real encoded fixtures, MediaDecoder or a real helper were excluded. Tests use private synthetic bytes, injected IPC metadata/native runners and ImageTransportStub. URLs only construct fake requests; no provider/network/download/paid call occurs. No actual codec/helper/image encoding, clipboard, app, audio, capture or permission operation. Every held gate is released and every task joined.

Build375.65s passed without changed-file warnings; unrelated warnings and the native-build deprecation remain. Inventory5.028s; test command26.18s; archive2.471s. Tracked core406.858s,409.329s including archive, excludes extraction/audit/platform work. No retries, timeout relaxation or Source/test edits after build. Each build, inventory, test, archive and extraction was completed and collected before its dependent step.

## Coverage evidence

Changed executable lines vs the stated base: **9/9 (100%)**, validator4/4 and service5/5. This is line coverage, not every branch/race/errno/native allocation/device proof.

Three fresh matching HOST profiles from one binary (XCTest discovery, XCTest execution, Swift Testing). Each raw individually validated, warning-free merge, matching app --object for llvm-cov show/export with empty stderr; both binaries contain __llvm_covmap and __llvm_prf_cnts. Prior live/root default profiles excluded. No old/cross-layout merge or child-process coverage claim. All1,136 Source +827 test Swift hashes match the post-build/pre-test snapshot and archive after extraction; live/archived binaries match. Zero Swift function hashes do not establish layout compatibility. No new production Source file.

Private evidence .build/generated-batch-authority-validation/final:

- Test host SHA-256: `93ff55ecbfb5c714246188d0c5ffe89d007cf59b20aa942e5333e913e98686e1`
- App SHA-256: `dd1e3b1db2d7b99c9b48560bb898114ebed75fdaec88632129536a6fce5258db`

## Remaining boundaries

Tool/history/sandbox batch integration and broader feature/native/media audit remain. Earlier settings receipts do not cover concurrent writers versus bind, direct defaults/distinct same-suite objects, or external preferences/account/OS FDA ordering. Original source/root/FDA/account/model/control consent, independent budgets and actual retirement remain unchanged. Stable mutation identity is required before future write retries; none are added here.

No real weights/CoreML/provider/network/download/home/network mounts/TCC/capture/mic/audio output/user clipboard/external apps/full suite/signing/hardware. No presentation/helper ABI/entry/package change, so no screenshot/copied probe. Audio/TCC/signing/performance precede microphone ownership. Real CoreML/model performance/full Xcode/DeveloperID/notarization/macOS13 Intel/actual quit recording remain unverified. HostFS/JSON/SQLite/raw memory/UI/AppKit/GPU/system memory remain boundaries; no arbitrary host/native crash/OOM/power-loss guarantee.
