## Local content search (GUL-383)

Launcher → Built-in Search → Files has an inline experimental content-search card, disabled by default. Setup and management stay inside the current settings page. Content search shares the filename search directories and exclusions; changing that scope reconciles both indexes. Apple Silicon, macOS 14+ and Metal are required; unsupported devices cannot enable the setting, including through a persisted preference. Filename search remains available independently.

Hidden files, configured exclusions, credential paths, symlinks, non-local mounts, packages and cloud-only placeholders are skipped. Full Disk Access is checked before indexing and again before returning results. Documents include UTF-8 text/Markdown/CSV/TSV/reStructuredText and text-layer PDFs. Scanned PDFs still require OCR. Document reads run in a cancellable filesystem child, with descriptor checks and bounds of 16 MB, 128,000 extracted characters, 500 PDF pages and 64 overlapping chunks per file. There is no artificial total-file, directory-entry or database-chunk quota. Discovery and deletion reconciliation use bounded batches and a disk-backed temporary queue.

Documents are processed before images, then audio, then video. Media work waits for 15 seconds without keyboard, pointer or scroll activity before each file and segment. Recording/processing, Low Power Mode and serious thermal pressure pause background indexing. FSEvents interrupt media reconciliation so newly changed documents take priority. Committed documents remain searchable while media is indexing, downloading its model or waiting for idle time. A media-model failure leaves document search available and offers retry.

The filesystem child makes a private, descriptor-checked snapshot before decoding media. Images are reduced to at most 1008 pixels, audio is streamed into 30-second mono 16 kHz windows, and video supplies a frame every 10 seconds plus its audio windows. Derived files are private, removed after embedding, and cleaned on cancellation/failure. Media vectors are staged on disk; a file becomes searchable only after every segment succeeds and its source metadata is revalidated. Unchanged media reuses its vectors without waiting for idle time. Corrupt/unsupported files are skipped; storage and runtime failures remain visible errors. Large media does not inherit the document-size bound.

The independent `SemanticSearch/semantic-files.sqlite` WAL database stores metadata, chunk text, PDF page numbers, media timestamps, FTS5 terms and normalized 768-dimensional Float32 vectors. The timestamp migration preserves existing document embeddings. CJK indexing/query tokenization is shared; lexical recall uses bigrams instead of common one-character overlaps and ignores English stopwords. Replacement is transactional; incompatible vector profiles are invalidated. Cancelled/incomplete scans never prune unvisited files. Query scope/type/extension/folder filters apply before ranking and current file metadata is checked before publication.

Filename hits publish first in mixed search and `f` mode. A quiet, nonselectable spinner row says that file contents are still being searched, including when no names match. Existing hits remain selectable and previewable while content arrives; selection survives late publication. Name hits retain their scores and match ranges, with content evidence merged onto the same file. Content-only hits cannot take the mixed launcher's default Return action. Content rows show a passage and page where available; opening/revealing/copying continues to act on the source file.

The right-side preview also works in `f` mode, including partial filename results. A content PDF opens the actual matched page and highlights the passage directly on its rendered page, with Unicode/whitespace normalization. Preview cache keys include the passage/page/timestamp so the same file can display a different match. Files without page evidence retain the first-three-page preview. Audio/video previews start at the matched segment. Media indexing does not add OCR or transcription text.

Queries use a separate interactive helper, a 160 ms debounce, a 16-entry query-vector cache and a 60-second helper idle timeout. Exact vector scanning reads SQLite-owned vectors directly with Accelerate, caches per-file eligibility during a scan, and materializes passages only for top results. Indexing helpers have lower scheduling priority; document inference releases its model before media starts. The index remains local: no file or query is uploaded.

The model is `ggml-org/embeddinggemma-2-GGUF`, revision `bfcd298762cc34d0357ece5ebdd31791a3a374d8`. Both downloads are verified and atomically installed, with progress/cancellation/retry:

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `embeddinggemma-2-Q8_0.gguf` | 309,855,456 | `2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135` |
| `mmproj-embeddinggemma-2-Q8_0.gguf` | 554,821,024 | `c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f` |

The extra media projector is downloaded lazily when idle media work first needs it. Clearing the content index turns the feature off and keeps verified models; removing models deletes both weights and the content index. Neither action changes source files or the filename index.

## Building and validation

`swift build` retains the normal macOS 13 app target. `bash scripts/build_semantic_helper.sh` builds the separate arm64/macOS 14 Metal/MTMD helper using pinned llama.cpp `4d756bc72bf00a4aacf410ae15a2d315f3db400d` (b11461). Developers need CMake and Xcode; `TYPEFLUX_CMAKE` can select CMake. Bundle scripts install/sign the helper under `Resources/LocalRuntimes/SemanticSearch`; Intel-only releases omit it. Users need no build tools or Python. DigUp's MIT attribution and bundled dependency notices are retained.

Focused suites cover content policy/store/indexing, media scheduling/extraction/runtime, content previews/progress and the affected filename/keyword/settings callers. Normal tests use isolated fixtures without downloads. Set `TYPEFLUX_SEMANTIC_TEST_MODEL` and `TYPEFLUX_SEMANTIC_TEST_PROJECTOR` to the pinned local weights to enable actual helper IPC image/audio inference; `TYPEFLUX_SEMANTIC_SCREENSHOTS` writes native appearance snapshots. The helper's English/Chinese retrieval smoke test is:

```sh
python3 scripts/validate_semantic_helper.py --helper .build/semantic/TypefluxSemanticHelper --model <pinned-model.gguf> --report <report.json>
```

Retrieval currently uses exact local vector scanning. OCR, transcription text, ANN extensions and cloud embeddings are outside this implementation.
