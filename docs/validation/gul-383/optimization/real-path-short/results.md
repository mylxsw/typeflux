# Results and review

The document-only probe passed with actual pinned weights and the production budget enabled. The complete resource wrapper took **397.24 seconds**, including checksums/clones, initial indexing, native setup, the five-minute window and cleanup. The child command took 397.13 seconds (exact value in `runtime-command.json`); no product build occurred inside either measurement.

| Check | Observed result |
| --- | --- |
| Initial real indexing | 2 files / 3 encoded chunks, 32.30 s including cold model setup; DOCX body and scanned-PDF OCR have distinct persisted 768-dimensional vectors. |
| Office / scanned invoice | INV-682914 -> DOCX body; INV-739204 -> PDF page2 OCR, with snippet, chunk ID and version. |
| Semantic query | “How can I get money back for travel?” returned the DOCX at rank2 and the PDF at rank1. This is a diagnostic small-corpus result, not a new cohort metric. |
| Native mixed entry | Last committed editor input to publish/layout: 296.41 / 359.16 ms, one sample. |
| Native Files entry | 101.16 / 117.74 ms, one sample; same persisted page2 OCR evidence. |
| Real file event | FSEvents write -> first matching complete service response: 11.66 s. The new file's real 3,072-byte vector was independently observed in the private database. |
| Reopen | A separate Store and real query worker retrieved the persistent DOCX hit. |
| Background/native window | 300.08 s; 29 repeated exact OCR queries, layout median26.61 / empirical p95 30.54 / max40.23 ms. Reported asynchronous service counters files/chunks:3/4 ->28/17; these are not final database/encoded-vector counts; pending work was not drained. |
| Independent native events | 300.00 s, IDs1..299 complete; zero missing handlers or WindowServer matches. Handler maximum236.25 ms, WindowServer empirical p95 28.37 / max256.53 ms. No one-second delay in this bounded document-only observation. |
| Host/resource | Apple M4,16 GiB host details in `environment.json`; memory pressure level2 throughout, sampled peak sum of owned RSS1,652,129,792 bytes. Shared pages overlap; this is not unique RAM or a watts measurement. |

Metal presentedTime remained zero, so those fields remain null; the independent compositor result comes from ScreenCaptureKit's exact generated event-ID bars. Its producer intentionally emits299 events in a300-second window, and every expected ID is present. This is separate from the search view's layout/accessibility timing. The29 repeated-query distribution is a small cached/exact-query sample; it is not acceptance of general semantic p95/p99, the two-entry background matrix, Release performance or long-term stability.

`first-hidden-scope-failure/` retains the **50.99-second** failed wrapper. `media-startup-timeout/` retains the **248.59-second** integrated media timeout. Probe compile/link phase records and the initial **13.38-second** compile failure remain; one intermediate command JSON was overwritten and is disclosed in `tool-history.json`. The probe-build scripts did not capture their full checksum/preparation wrapper wall time, so compile/link phase durations are not presented as whole-command build times. No accepted production batch or full suite was repeated to fill this tooling record gap.

The source/binary used for the successful runtime is frozen in `runtime-tools/` and `probe-binary.json`. Self-review then corrected the Python timeout cleanup path: a native-probe timeout after the app already exited could signal an already reaped leader. The final runner safely handles live, reaped and absent owned processes; a focused actual-child retirement check passed in `cleanup-tool-check.json`. The runtime was not repeated for this unused cleanup-branch fix. Current tool fingerprints and the exact earlier runtime tool source are both retained.

Self-review covered input -> real extraction/model -> durable vectors -> both native result entries; file event/reopen; missing/failed cases; cancellation/owned process joins; private clones/defaults, path/symlink boundaries inherited from accepted code; restoration and source/tool/model compatibility. Fixed the invalid probe API, hidden fixture root, explicit budget selection and timeout cleanup. `process-cleanup.json` found no retained runtime PIDs or private roots. Python compilation, raw-report assertions and `git diff --check` passed. No application/helper/runtime source changed, so all three new changed-executable-line denominators are0/0 N/A; previously accepted coverage is reused.

Screenshot visual/text, audio boundary and short-video real-model integration remain unverified after the media startup timeout. The exact projector checksum was verified, but that alone is not inference or quality evidence. The failure has no isolated root cause yet. GUL-405 and its parent remain in progress; no merge or GUL-406 action was performed.
