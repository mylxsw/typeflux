# Fixed screenshot answerability diagnosis

PR648 continues from `ec042921502bc63b6cefdfe7f406ed782cd830b9`. This slice changes diagnostic tools and evidence only. The fixed screenshot visual query **still fails**. No production gate, ranking, prompt, model, timeout or budget changed. The earlier utility/native CPU-registration fixes remain in the draft PR. GUL-405 and GUL-383 remain in progress; audio 30/25-window and short-video retrieval remain pending, and GUL-406 was not opened.

The previous private database was deleted during cleanup. We used the authorized **one** bounded acquisition of the same screenshot and exact query, with the current product workers/helpers, normal utility CPU budget and existing 40-second observation cutoff. The entry point adds vector export, SQLite backup and rejection reporting; it is a **diagnostic capture**, without DYLD injection or helper-stage instrumentation. It does not replace the earlier uninstrumented product result or establish final UI acceptance.

Apple M4, 16 GiB, macOS 26.6.2 (25G83); Debug product objects and optimized product inference helper. The pinned model/projector hashes are `2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135` / `c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f`. Eleven direct production source files match the accepted cache byte for byte; helper hashes match the previous product evidence. No full inventory or app/native-helper rebuild was repeated.

## What rejects the query

`black text on a white background` is unchanged by the service query policy. `SemanticEmbeddingWorker.swift:347` adds the same `task: search result | query: ` prefix used by the retained real-model media oracle. The native helper mean-pools and normalizes both inputs. No prompt/provenance incompatibility or numerical defect was found.

| Stage | Image | OCR |
| --- | ---: | ---: |
| Dimensions | 768 | 768 |
| Norm | 1.000000044 | 0.999999994 |
| Float32 reference dot | 0.693839738 | 0.649667190 |
| Production Float16 scanner cosine | 0.693842411 | 0.649659693 |
| Raw ranking score | 0.381613326 | 0.357312831 |
| Script adjustment | 0 | +0.025 |
| Ordering score | 0.381613326 | 0.382312831 |

Generated image Float32 bytes equal persisted bytes exactly. Quantization errors are below 0.000008, far smaller than the missing 0.006158 absolute confidence margin. Both chunks have the expected model/projector/prompt/segment provenance, valid versions and permitted scope/type; the OCR chunk has the expected OCR recipe. Neither chunk contains lexical evidence for the fixed visual query.

The path is **2 stored → 2 compatible → 2 eligible → 2 non-nil scores → 1 distinct file → 0 published candidates**. Both chunks pass `score`'s 0.45 semantic floor. `SemanticVectorReader.swift:468` then calls `SemanticSearchRanking.confident` (`SemanticSearchRanking.swift:110`): peak 0.693842411 is below 0.70, complete lexical evidence is absent and runner-up is nil. The OCR chunk shares the file and correctly does not become another-file runner-up. The final rejection occurs here, after scoring; ordering calibration does not explain the miss. Service and reopened Store both returned zero hits.

Self-review found a separate ordering detail: if confidence were bypassed, the existing +0.025 text-script adjustment makes the OCR chunk narrowly beat the visual chunk for this same file. The final offline replay calls the actual production adjustment function and retains both scores. Therefore merely bypassing the absolute gate would not even establish the required image-segment result. This hypothetical ordering is reported separately from the actual confidence rejection; no bypass was applied.

## Why no threshold patch

Offline replay uses the saved database and real vectors from the existing fixed oracle, without inference or new labels. On this **one-screenshot database**, original no-answer remains 0/25 and existing media no-answer remains 0/25; maximum peak is 0.576841354. Error code `ERR-739204` and quote `"Connection failed"` retrieve OCR; near code `ERR-739205` and missing quote `"Connection succeeded"` do not. This is not a full-corpus no-answer or Recall@5 result. The original denominators/labels were not changed; color-pair diagnostics are not added to them.

A necessary counterexample also comes from the existing same-model/projector image oracle: `a red square` scores **0.698181987 on the nonmatching blue square**, higher than this screenshot's 0.693842411. Therefore any single absolute cosine cutoff low enough for this screenshot also accepts that known wrong color when it is the only file. The current 0.70 gate separates all six existing matching color pairs from all six nonmatching pairs. This rules out a safe scalar-cutoff repair, including applying the lower cutoff only to image peaks. No parameters were fitted to this screenshot.

The remaining work needs evidence beyond the current scalar file peak and must retain the correct winning segment: evaluate a separately validated visual/OCR agreement rule or a representation correction against the existing fixed positive/negative oracle. Start with `synthetic.sqlite`, the exported image/query vectors and the existing color pairs; **no more screenshot encoding or loader diagnosis is needed**. The present evidence does not justify choosing new agreement weights or claiming screenshot-group Recall ≥85% / overall false positives ≤5%. The fixed visual failure remains explicit instead of substituting a different query.

## Commands and verification

From the repo root, where `<accepted-cache>` is the previous accepted checkout and `<model-cache>` its `.build/model-assets`:

```sh
python3 docs/validation/gul-383/optimization/media-isolation/visual-diagnosis/build_probe.py --cache-checkout <accepted-cache>
python3 docs/validation/gul-383/optimization/media-isolation/visual-diagnosis/run_capture.py --cache-checkout <accepted-cache> --model-assets <model-cache> --media screenshot --stage-seconds 40 --fixed-helper <accepted-cache>/.build/stage-budget/ProductSemanticHelper --product-runtime --label fixed-capture
python3 docs/validation/gul-383/optimization/media-isolation/visual-diagnosis/build_probe.py --cache-checkout <accepted-cache> --offline
XCODE_DEVELOPER_DIR="$(xcode-select -p)"
DYLD_FRAMEWORK_PATH="$XCODE_DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks" DYLD_LIBRARY_PATH="$XCODE_DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib" LLVM_PROFILE_FILE="<repo>/.build/visual-diagnosis/offline-%p.profraw" .build/visual-diagnosis/OfflineReplay <repo>
python3 docs/validation/gul-383/optimization/media-isolation/visual-diagnosis/analyze.py
python3 -m unittest discover -s docs/validation/gul-383/optimization/media-isolation/visual-diagnosis -p test_analysis.py -v
```

The build command/arguments, phases and return codes are retained in `build.json` and `replay-build.json`. Capture compile/link took 9.192 s; offline compile/link took 8.368 s initially and 10.726 s after adding the missing script-adjustment observation, with no compiler failures. Both offline sources/results/build records are retained. The capture command took 25.866 s and exited **1** because visual acceptance failed; the job reached ready with both chunks at 19.797 s. The initial offline production Store/scanner replay took 4.368 s and exited 0; the final replay duration is retained in `offline-command.json`, reproducing the failure and checking 50 existing negatives, four exact lexical cases and twelve existing color pairs. These are service/Store diagnostics, not native UI latency or long resource stability. No old format/loading/resource matrix was rerun.

The runner's legacy builder snapshot was relabelled `legacy-product-link-reference.py`; `build_capture_executed.py` preserves the actual capture builder before offline support was added. One metadata collection attempt failed when trying to make an accepted-cache binary relative to the current checkout; role labels repaired that metadata without rerunning the capture or model. The failure is retained in `metadata-retention.json`.

New production executable lines: application **0/0**, native helper **0/0**, file helper/media runtime **0/0**, all N/A. Existing PR648 coverage remains application **3/3** and native helper **4/4**, with the previously reviewed 12-method focused run reused because product sources did not change. Four initial diagnostic artifact tests passed. After self-review added the actual script-adjustment observation, only the affected readback method and one new ordering method were run; five distinct methods pass in total. These tests check readback/quantization, precise failure attribution, existing negative denominators/exact lexical behavior, the scalar-cutoff counterexample, and malformed-vector rejection. Their command durations/results are recorded in `validation.json` and `validation-ordering.json`; no new application coverage run was warranted.

## Self-review and retention

Reviewed the full query/prompt → generation/normalization → durable bytes/compatibility → candidate/score → confidence → Store/service result chain. Checked the single-file/two-chunk edge case and an existing wrong-color counterexample rather than assuming a ranking defect. No production ownership, cancellation, generation, permissions, default switch, resumption or resource policy changed.

Only a synthetic screenshot and fixed synthetic queries are retained. The SQLite backup was made before service clear, its paths replaced by `/gul405-synthetic`, then vacuumed; integrity and offline readback pass. The original private directory was removed, all five observed PIDs are absent, and the normal service cleanup completed; no process-name termination was used. Profiles, executable hashes, executed probe sources and the synthetic database/vectors are retained. The attached binary archives preserve the final executed capture and replay binaries; reused product helpers retain their previous verified binary references. The diagnostic tools are opt-in and are not invoked by the app. No safe production behavior fix is claimed for this slice.
