# Small file icon accepted native batch

The default SmallFileIcon consumer now binds the existing preview worker availability at accepted AskContextImageModel entry, before its pixel reservation and child Task. The concrete file-icon preparation passes that same authorization through the existing direct decoder and checks it again after terminal source authorization, before NSImage publication.

The Environment key stores an optional custom decoder. Its legacy nonoptional getter and setter remain compatible; the production View reads the optional override so it can distinguish the native default from independent custom/actor decoders. The Context initializer retains its last optional decode parameter and trailing closure syntax. No availability snapshot occurs at object initialization or body construction.

Context source/scope ownership and failed-value/epoch deduplication remain intact. Health recovery does not retry the input; cancel/reopen or a new explicit scope identity can accept a new operation. Completed valid pixels survive later health changes. The existing private-file bounds, edge 56, two decoder slots, pixel reservations and native/private-copy/child-host collection stay unchanged. No native grant, pool, generic dispatcher, full DI, scheduler hook, helper ABI or automatic producer/download/copy/export retry was added.

## Validation scope

The new tests run the actual default Context-to-file-icon preparation with a private input reader and fake worker. A read-only observation of the existing standalone budget clock records the first task hash inside withUnsafeCurrentTask; only the scalar hash is retained. It establishes where the default availability snapshot occurred in that fixture, without controlling scheduling. Managed-worker recovery is tested separately. This is not an exhaustive executor or task-identity proof.

Held reader and native fixtures prove refusal across recovery and physical collection after cancellation. They release every gate and join every caller. Synthetic successful responses echo imageType, use fixed 2×2 RGBA and are protocol-validated. A terminal source callback asserts valid completion and native activeCount zero before revoking the original availability. Custom actor and legacy Environment paths stay independent of an unready native worker.

Selected regressions are SmallIconAuthority, ContextImageAuthority, ContextImageSourceOwnership and two explicit SmallIconIsolation boundary methods. The method inventory is recorded separately. No real codec, encoder, helper, network, app icon, OSQuickLook, window, pasteboard (including named), SystemClipboardContentActions, ConversationModel, AskTestFixture, home/Downloads, provider, paid call, audio, capture, TCC, device or full-suite execution is included. SwiftUI body construction is VALUE ONLY: no host, rendering, window, task launch or symbol resolution.

## Limits

This covers accepted DEFAULT SmallFileIcon model requests and the audited synchronous source callback boundaries. The legacy default Environment getter used directly retains the direct decoder entry contract. Browser favicon outer chooser and native application fallback remain separate; their cache and direct decoder fixes do not establish the earlier chooser batch. OSQuickLook is untouched. No arbitrary Published/Combine/AppKit reentrancy, all UI epoch, FS/settings/account permission transaction, rollback of entered reads/effects, global heap, crash/OOM or power-loss guarantee is claimed.

No presentation layout, package, helper entry or ABI change is made, so no screenshot or copied-helper probe is required.

## Results and reproducibility

Baseline `f629bfab7bf62bbf917423e90af916b6b5486c62`. First functional pass: **28/28 distinct methods** — 2 XCTest in 0.030s and 26 SwiftTesting across four suites in 0.378s. New suite: seven methods/eight parameter cases. All gates released, callers joined and owned registries shut down. No functional retry, assertion correction or timeout relaxation.

Changed executable coverage: **32/32 = 100%**, Context 7/7 and SmallIcon 25/25. This is line coverage, not all branches/races/errno/devices/runtime DI proof. No Sources or Tests were edited after the final build.

Initial build passed in 281.93s with two new Sendable conversion warnings. Before any functional test, the Environment override was wrapped in a concrete Sendable value and the legacy default closure explicitly marked Sendable. Final build passed in 200.15s with no changed-file warnings (unrelated warnings/native build deprecation remain). Inventory 4.178s; focused command 32.65s; archive 2.493s. Core 518.908s, with archive 521.401s; excludes extraction, audit, platform and delivery time. Each build/inventory/test/archive/extraction was collected before its dependent stage.

Three fresh HOST profiles from one final binary (XCTest discovery/execution and SwiftTesting). Each raw profile validated, warning-free sparse merge, matching app object supplied to coverage, empty show/export/all-functions stderr, both LLVM coverage sections verified. All 1,149 Source and 857 Test Swift input hashes (2,006 total) match final PREBUILD/live/archive snapshots after extraction. Live/archived binaries and original/copied raw hashes match. Prior live/root-default profiles were moved aside; a new root default profile from pre-test inventory is also excluded, never merged. No old/cross-layout/child coverage claim. All 789 reported function hashes are zero; this does not establish layout compatibility.

Final test binary SHA-256: `f024fb33a8d5e9c303685149276ad3b100e78009697a33cb3a354e9f01a0fdf1`. Matching app: `cecca1c2e5677354294d5b151af5d112fecd31b9e3f31b56947153497407ca74`. Private archive: `.build/small-file-icon-batch-authority-validation/final`. Full method list, exclusions and coverage are in the adjacent JSON reports.
