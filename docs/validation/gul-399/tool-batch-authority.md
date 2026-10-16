# Tool and history image batch authority

Validated base: main `427806fa2b471a4b6e9ca1e2a51d0f0618e4dd4c`.

## Behavior and self-review

AskTypedContent.output, prepare and prepareHistory now capture one concrete AskToolImageNormalizer.Batch at their accepted outer entry. Output and history pass that same batch into private preparation instead of recapturing native availability per image or message. Sandbox firstImage binds once across its candidate loop. The batch keeps the existing worker authorization and cancellation predicate; each native call receives the original stamp. A later image/candidate cannot adopt a recovered managed generation, while a fresh explicit invocation can.

Default batch invalidation clears temporary preparedImages and withholds the affected projection before return. History clears old typed legacy image fields and invalidates only its owned recent12-message window after cancellation or retirement, including proofs completed earlier in that invocation. Raw result blocks/status and private program files remain. Withheld receipts do not silently retry preparation. Text/structured-only results remain available without native readiness. Earlier UI/source/account consent is still the caller's responsibility; this batch starts at the consumer function entry.

Optional custom normalize closures keep their independent contract, including actor implementations, without a forced native-health dependency. Existing trailing-closure call forms remain supported. Immutable per-call receipt-parser and private-file-reader dependencies default to the existing bounded base64 parser and workspace read. They provide local source-preparation boundaries; no global scheduler hook or bypass was introduced. The production parser is bounded by existing receipt limits. Parser/read checks before and after preparation cannot roll back already-entered effects or make filesystem/settings/permissions linearizable.

Self-review before functional tests traced MCP output, local engine image preparation and prompt projection, result serialization/negotiation, and sandbox post-execution consumption. The engine still persists the completed tool receipt before awaiting image work and checks cancellation/conversation revision before queuing inference. No workflow/tool/program/generation is rerun. No native helper/protocol/entry/package change, new pool, generic dispatcher, full DI, per-view ModuleHandle, health grant or recovery operation. Native/facade slots and FD/private-copy/child/host ownership stay occupied through actual return. Existing image4/history8/recent12/candidate4 and byte/proof limits remain. No writes, paid requests, installs, exports or commands are retried.

## Focused validation and correction history

Using scripts/test_runtime.child_environment:

```sh
swift build --build-system native --build-tests --enable-code-coverage --jobs 4
swift test --build-system native --skip-build --enable-code-coverage --no-parallel --filter '<explicit inventory in tool-batch-authority-methods.json>'
```

Native_tools/native_environment/swiftpm-testing-helper inventories use actual names, not XCTest as a program. **41 distinct methods have passing results across runs; this is not a single41/41 pass.** Initial run:22 XCTest methods in five suites passed (0.271s execution),17/19 Swift Testing methods passed in three suites (0.565s total execution). Two new methods failed assertions comparing JSONValue.data across JSON serialization. JSONValue reconstructs dictionaries without sorted keys; byte equality was the wrong round-trip contract. Both failures had cleared preparedImages as expected. Only fixture assertions changed to compare JSON objects; production Source hashes stayed identical. The final affected suite passed8/8 methods (12 parameterized cases,0.495s), including the two corrected methods. The other33 initial passing methods were not rerun. Six initially passing methods in the affected suite were rerun. Final inventory lists the exact eight.

Eight new methods establish:

- Direct preparation, MCP output and history held at the second original block parse after the first normalization actually returned (native activeCount zero). Disable/start prevents later native work and clears the entire ephemeral batch proof; raw blocks/status remain. History crosses a message boundary. Fresh explicit operations succeed.
- All three pre-ready entries perform no parser/native work or readiness replay. Pre-canceled entries return withheld proofs with no native dispatch. Withheld receipts stay withheld.
- Sandbox candidate one finishes with a controlled native refusal, candidate two's private read is held across recovery, and no later native call adopts the new generation. Original files remain; fresh explicit projection succeeds.
- Cancellation during the second parser prevents publication of the earlier proof. JSON round-trip retains semantic raw content while proof remains untrusted; network/legacy projections cannot disclose withheld images or replay a producer.
- Two canceled uncooperative native operations keep facade/native capacity until physical return. Both are released/joined and late proofs discarded.
- Custom actor normalization remains independent of native readiness; history retains its eight-image/recent12 window and older raw content. Structured-only output stays available.
- Malformed input/proof, image count, aggregate byte limits and serialization preserve raw receipt fallback without trusting serialized proof.
- Sandbox pre-ready entry performs no reads; custom failure visits at most four candidates and preserves custom success behavior without native admission.

Selected existing methods:ImageDataAuthorityTests6,GeneratedBatchAuthorityTests5,MediaWorkerTests8 excluding real helper,MediaPreviewModuleTests3(independent budgets/corrupt health/expected refusal),AskToolImageIsolationTests1(uncooperative admission),AskGeneratedImageIsolationTests6(private receipts/budgets/fake downloads/retention failure/protocol/cancel),AskTypedContentTests4(opaque structured content/legacy accessors/trusted negotiation/legacy projection). Each selected body was reviewed. Real encoded-image/helper methods and local-engine methods using actual image encoders were excluded. New tests use private bytes, a handcrafted JPEG envelope for pure IPC validation, injected native results, parser/readers and private files. No codec/helper, actual clipboard, provider/network/download/paid call, app, capture or audio operation. All held gates released and tasks joined.

First build132.82s passed but added trailing-closure deprecation warnings. Parameter ordering was corrected before functional tests; second build62.12s passed without changed-file warnings. Fixture-only correction build80.16s passed without changed-file warnings; unrelated warnings/native build-system deprecation remain. Inventories4.566+8.299s; tests37.69+14.15s; archives38.108+30.378s. Tracked core339.805s,408.291s including archives, excludes extraction/audit/platform work. No timeout relaxation. Every build/test/archive/extraction completed and was collected before dependent reads or input edits. No Source/test edits after the final build.

## Coverage evidence

Final affected suite alone covers changed executable lines vs stated base: **53/53 (100%)**, typed content40/40,normalizer7/7,sandbox6/6. Line coverage is not every branch/race/errno/native allocation/device proof.

Only TWO fresh final HOST profiles from one binary (XCTest discovery and Swift Testing host). Every raw individually validated, warning-free merge, matching app --object for llvm-cov show/export with empty stderr. Both binaries contain __llvm_covmap and __llvm_prf_cnts. Initial functional run's three profiles and binaries are archived separately and excluded from final coverage. Prior live/root default files excluded. No old/cross-layout merge or child-process coverage claim; zero Swift function hashes do not establish layout compatibility.

All1,136 Source +828 test Swift hashes match the final prebuild snapshot and archive after extraction. Production Source hashes also match the initial functional archive. Live/archived binaries match. No new production Source file.

Private .build/tool-batch-authority-validation/final:

- Test host SHA-256:`5fc2d15a6f55d1f777ede0087fab132d35aeac84aa5cf801fb7fb004bc0f248e`
- App SHA-256:`d42d43eb4ebcbed22cea0d20aa61b4489df1a5cb1670a409f7cee85b3841b7b6`

## Remaining boundaries

The generation response batch is already integrated by #594; this increment completes the default tool/history/sandbox outer loops. Broader feature/native/media admission audit remains, including other legacy MediaWorker consumers. Custom wrappers/standalone owners retain responsibility for their underlying native epochs. Earlier UI/account/source transitions are not stamped retroactively. Settings receipt limits remain:concurrent writers versus bind,direct defaults/distinct same-suite objects,external preferences/account/OS FDA ordering. Original consent, independent budgets and actual retirement remain unchanged. Stable mutation identity is required before future write retries; none are introduced.

This base includes #587 GUL-404. It is compiled here, but these tests do not independently validate indexing-budget behavior. Preserve prior launcher/icon/cache/session/plugin, storage-only automatic quarantine reset, checkpoint/subtree/prune/rescan and chat/background changes.

No real weights/CoreML/provider/network/download/home/network mounts/TCC/capture/mic/audio output/user clipboard/external apps/full suite/signing/hardware. No presentation/helper ABI/entry/package change, so no screenshot/copied probe. Audio/TCC/signing/performance precede microphone ownership. Real CoreML/model performance/full Xcode/DeveloperID/notarization/macOS13 Intel/actual quit recording remain unverified. HostFS/JSON/SQLite/raw memory/UI/AppKit/GPU/system memory remain boundaries; no arbitrary host/native crash/OOM/power-loss guarantee.
