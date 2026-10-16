# Native icon original admission authority

AskFinderIcon.decode now captures existing worker availability after pure target/edge validation and before its two-slot queue. It retains the same authorization across queue admission, the existing shared-worker wait, detached renderIcon, native extraction and final return. MediaPreviewDisplay.renderIcon accepts an optional original authorization and forwards it through its existing private decoder to worker.perform. Existing callers remain source-compatible.

The worker defaults to the same previews domain. No grant, pool, generic dispatcher, full DI, per-view handle, global bypass, scheduling hook, helper ABI or package change was added. The existing native target policy, edge 1–112, two icon permits, shared native capacity, 3-second/20ms wait and actual-return collection remain. Custom Environment/actor decoder contracts are unchanged. No health event retries the input.

## Test scope and proof limits

New tests use the actual direct decoder, a never-executed fake executable URL and injected runner. Requests and successful responses are protocol-validated; nativeIcon has one raster, no imageType, page, geometry, waveform or duration. Only private fixed RGBA bytes enter the host.

The default queued-entry test holds both real icon admission permits with uncooperative fake native calls. A separate standalone worker's existing read-only budget clock observes authorization/permit checks before that worker can obtain an icon slot. The worker then binds to its own managed module and goes through disable/start before the queue opens. The old default call cannot adopt that later lifecycle; a fresh direct call succeeds. This tests a standalone-to-managed ownership transition followed by managed recovery, not a default request captured in an already-managed generation. An independent explicit-original managed stamp fixture covers disable/start forwarding; its original stamp is captured before queuing, without claiming an exhaustive executor freeze.

The shared-worker wait test fills native capacity through two injected preview operations and observes repeated checks from the waiting direct task through the same existing clock. Only UnsafeCurrentTask.hashValue is computed inside withUnsafeCurrentTask; no task object escapes or is sent. The clock returns actual uptime, never blocks or changes scheduling. Task-hash observation is not arbitrary executor/task-identity or race proof.

Canceled uncooperative native calls keep their native and icon occupancy until actual runner return; a canceled queue client never dispatches. Gate releases and all caller joins are explicit. The late-valid-response fixture validates success inside the fake runner before revoking its own admission. It is not a precise freeze after successful host extraction/helper return.

Selected existing bodies and helpers were reviewed. Native allowlist/protocol/canceled-queue and Context target-contract cases are pure refusal or fake dependencies. SmallIconAuthority regressions use private bytes, raw pixels and injected JSON. The injected native adapter test is excluded because it also invokes a system lookup. Real-helper, actual native lookup, windows, encoders, app/launcher object construction, System clipboard (including named), Downloads/home, ConversationModel/AskTestFixture, provider/network/paid calls, capture/audio/TCC/devices and full suites are excluded.

## Remaining boundaries

This is a direct admission prerequisite. Earlier BrowserFaviconView chooser, AskNativeIconImage custom Context closure and LauncherIconCache accepted/prefetch batches remain separate. In particular the launcher cache also has synchronous NSWorkspace immediate lookup; that lane is untouched and unrun. OSQuickLook remains separate. No source/account permission is inferred from native health; entered effects cannot be rolled back. No FS/settings/account transaction, all UI epoch, arbitrary Published/Combine/AppKit reentrancy, global memory, host crash/OOM or power-loss guarantee is claimed.

No presentation layout, package or helper entry/ABI change means no screenshot or copied-helper probe is needed.

## Results and reproducibility

Baseline `ebf516a7f410dc047d246627f40709c08542fe68` includes #624 OCR preview changes. Those unrelated behaviors compiled but were not independently functionally validated.

**16/16 distinct methods passed on the first functional run:** four XCTest across two suites in 0.021s and twelve SwiftTesting across two suites in 0.240s. Six new methods. No functional failure/retry, fixture correction, timeout relaxation or Source/Test edit after the build. All gates were released, callers joined, native active counts collected and owned registries shut down.

Changed executable coverage: **11/11 = 100%** (FinderIcon 9/9, display facade 2/2). Line coverage does not prove all branches/races/errno/devices/runtime DI.

Build passed in 292.06s (Swift internal time 288.35s), inventory 4.408s, test wall 24.27s, archive 2.537s. Core 320.738s; with archive 323.275s, excluding extraction, audit, platform and delivery. Each stage was collected before dependent reads/edits. No new changed-line or test-file warnings. A pre-existing Sendable conversion warning in unchanged AskNativeIconView code (old line 104, now 112) and unrelated warnings/native-build deprecation remain; this is not a warning-free whole build.

Three fresh HOST profiles from one binary: XCTest discovery/execution plus SwiftTesting. Each raw validated, warning-free sparse merge, matching app object supplied, empty show/export/all-functions stderr, both LLVM sections verified. All 1,150 Source and 860 Test Swift input hashes (2,010 total) match PREBUILD/live/archive snapshots after extraction. Live/archived binaries and original/copied raw hashes match. Prior live/root-default profiles moved aside; new pre-test-inventory root default separately excluded. No old/cross-layout/child coverage claim. All 700 reported function hashes are zero, which does not establish layout compatibility.

Test SHA-256: `cf8f2fc20a1d8f138419fd7732b689f1d45c278018259256f5d8d44e4054c9d8`. Matching app: `09e266811058e434ddb50048dd8558972ff82bbe2e004559c86a521f873b2315`. Private archive `.build/native-icon-authority-validation/final`; method inventory, exclusions and coverage proof are in adjacent JSON reports.
