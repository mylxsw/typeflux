# Small-icon preparation authority

`AskSmallIconDecoder` now captures the existing preview worker authorization before reserving its two-slot admission or preparing file/data input. The same immutable authorization is checked around detached preparation, forwarded into native rendering and checked after the actual return. An old preparation cannot adopt a recovered native generation. A fresh explicit invocation can use current availability; readiness never replays input.

An optional original authorization supports concrete outer continuations without recapturing at native entry. A narrow immutable `InputReader` preserves the same production bounded read: data up to 256 KiB; nonblocking open, regular-file check and bounded read up to 4 MiB; FD closure before native decoding. Source/symlink policy and the 56-pixel result limit are unchanged. Custom readers own their preparation contract. Slots remain held through actual detached/native return, including uncooperative preparation. Native private-copy/FD/child/host leases and independent budgets are unchanged. No new grant, pool, generic dispatcher, full DI, helper ABI or packaging change was added.

## Scope and review

Baseline is `6c617e30d6704430098b8f1f69a2abf3256c47e7`, read immediately after branch creation. Reviewed all decoder callers, `MediaPreviewDisplay`, favicon cache/view, and all bodies in `SmallIconIsolationTests` and the selected worker tests before choosing the scope. Implementation and self-review preceded functional testing.

This boundary starts at direct decoder entry. `AskSmallFileIcon` uses a custom context decoder; earlier view preparation is not stamped by this increment. The default favicon cache also waits for its loader before entering the direct decoder, so its original download/native batch continuity remains work. Custom raw-pixel decoders remain independent. Completed valid images are not retroactively erased merely because health later changes. OS QuickLook, native application-icon fallback and actual app/file-index objects were not changed or exercised.

This is not an atomic filesystem/settings/account permission transaction, arbitrary UI-epoch guarantee or rollback of entered reads/effects. Source/account/control consent remains with callers. There is no automatic retry, redownload, producer/workflow/tool/command/paid-generation replay, export/copy/write retry or deletion for recovery. Earlier document-indexing and other main changes compile in this binary but are not independently functionally validated here.

## Focused validation

**21/21 distinct methods passed on the first functional run:** 15 XCTest methods in two suites (0.110 s execution) plus six Swift Testing methods in one suite (0.113 s). Exact inventory and exclusions are in `small-icon-authority-methods.json`.

Six new methods include eight cases: pre-ready/precanceled/retired/foreign requests do no preparation/native work and do not replay on readiness; held file/data preparation across actual managed recovery rejects the old request while an explicit fresh request works; two canceled file/data preparations retain both slots until actual return; two canceled injected native calls retain native and decoder capacity until physical return and reject valid late replies; a valid synthetic response followed by original-admission revocation is refused without retry; bounded production reads preserve private bytes and reject invalid sources. All gates were released and tasks joined.

The revocation fixture validates the synthetic response inside the injected runner before revoking its own admission. It does not freeze execution precisely after a successful presentation helper return. Tests do not prove every scheduling interleaving.

Existing selected tests check input/output limits, cache/download cancellation, shared waiters, original source/scope permission, cache capacity, pixel leases and shared native-worker retirement. The test named decoder-admission cancellation uses `png()` encoding and was excluded despite its fake runner; new private-byte fixtures replace that coverage. No actual codec/helper, image encoder, Vision, URLSession/HTTP, provider/paid calls, pasteboard (including named), System clipboard actions, home/Downloads, apps/windows, capture/audio/TCC or full suite ran. Fake runners return bounded JSON/RGBA without executing their executable URL. No presentation/ABI/entry/package change required a screenshot or copied-helper probe.

**Changed executable coverage: 29/29 (100%)** in `AskSmallIcon.swift` against the baseline. The 90% goal is met; this does not prove all branches, errno, devices, production DI or source races.

| Foreground stage | Wall seconds |
| --- | ---: |
| Initial native coverage build | 75.340 |
| Final native coverage build | 94.510 |
| Prebuilt native inventory | 4.054 |
| Explicit no-parallel skip-build coverage test | 24.730 |
| Evidence archive | 3.201 |
| Builds + inventory + test | 198.634 |
| Including archive | 201.835 |

Extraction, source review and platform delivery time are additional, not separately timed. Initial build passed with a new default-reader Sendable-conversion warning. Its default was changed to an explicit closure before functional testing. Final build passed with no changed-file warnings; unrelated warnings and SwiftPM native-build deprecation remain. There was no functional retry or timeout relaxation. No Source/test inputs changed after the final build. Every build/inventory/test/archive/extraction job completed and was collected before dependent input edits or reads.

## Evidence integrity

Only three fresh matching HOST profiles from one final binary were used: XCTest discovery, XCTest execution and Swift Testing execution. Each raw was individually validated. Sparse merge, matching-app-object show/export and all-functions inspection had empty stderr. Both binaries contain LLVM coverage sections. **1,145 Source + 846 test = 1,991 Swift inputs** match the FINAL PREBUILD snapshot, live tree and archive after extraction. Live/archived binaries and original/copied raw hashes match. Prior live and root default profiles were excluded; there is no old/cross-layout or child coverage claim. All 808 reported function hashes are zero; zero Swift hashes do not prove layout compatibility.

Private evidence: `.build/small-icon-authority-validation/final`.

- Test binary SHA256: `66f1df1aa390fd97d11f725f9dbd7db7c5a115463310b09b3ff534b4801d5d06`
- App binary SHA256: `e0bdd0f8fce811ec18ec3d0a585daaf254435a07631f65b5ee80b053b00fd856`

Broader GUL-399 remains in progress, including favicon/default outer-consumer continuity, artifact denied-entry/source projection, clipboard image-copy and custom native OCR outer requests, and external condition ordering. Real model/device/performance/signing/full-Xcode/macOS-13-Intel/actual quit-recording checks remain unverified. Host filesystem, JSON, SQLite, raw memory, UI/AppKit, GPU and system-memory boundaries provide no arbitrary crash/OOM/power-loss guarantee.
