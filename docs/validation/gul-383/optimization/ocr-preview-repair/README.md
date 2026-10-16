GUL-405 / PR624: preview evidence validation repair

The reported blank image is not present in either archived PNG examined here. Direct ImageIO decoding and Apple Vision recognition of the right-hand image region find all three original lines, including `Error ERR-739204`, in both the developer and independent reviewer captures. Each contains 3,049 yellow pixels and 1,086 dark ink pixels in that region. Their SHA256 values match the original developer provenance and reviewer finding. See `archive-audit.json`, `developer-reported-blank.png`, `arch-reported-blank.png` and the unchanged `arch-original-finding.json`.

The mismatch between the recorded visual finding and these PNG bytes remains unexplained. This investigation does not establish a production rendering defect or a capture-timing defect, and does not claim to have fixed either. No production source, theme, image representation, helper, permission/version check or window lifetime was changed. The old `ocr-preview-slice` evidence directory is preserved byte for byte.

The confirmed defect was the size-only snapshot assertion: a PNG with a blank preview and intact result-list text would pass. The existing integration test still obtains the same persistent OCR hit from real local PNG/JPEG indexing and renders the production mixed/file-plugin results beside `AskFilePreviewView` in native windows. It now explicitly completes pending view drawing before caching, decodes the exported PNG, crops only the image area, requires recognition of the error code, and checks tolerant ink/highlight counts inside its recognized bounds. Highlighted and unlocated fallback captures are checked in both appearances and both entries. These are region-level checks, with no font-specific pixel comparison.

The negative control erases only the production snapshot's image area while retaining its header and searchable result text. It remains larger than 1,000 bytes, passes the former assertion, and fails the new readable-preview predicate. It is saved as `blank-preview-control.png`. Historical captures are also checked by the same predicate when the evidence runner supplies `TYPEFLUX_OCR_PREVIEW_BASELINE`.

Reproduce the focused validation from the repository root:

```sh
python3 docs/validation/gul-383/optimization/ocr-preview-repair/run-coverage.py --name coverage-repair
```

This executes `make coverage FILTER='SemanticOCRPreviewTests/.*persisted'` with the recorded explicit test-source closure and coverage-preserving Swift wrapper. The two parameter cases cover PNG and EXIF-6 JPEG, persistent hit geometry, scaling, unmatched/stale/visual fallback, file version replacement and both-entry preview snapshots. The original four-suite validation is reused for unchanged production behavior; this repair adds no production executable lines to the application or shared media helper.

To inspect the reported artifacts without any view hosting or screenshot viewer:

```sh
swift docs/validation/gul-383/optimization/ocr-preview-repair/audit-archives.swift \
  docs/validation/gul-383/optimization/ocr-preview-repair/developer-reported-blank.png \
  docs/validation/gul-383/optimization/ocr-preview-repair/arch-reported-blank.png
```

These captures remain synthetic-fixture native production-view evidence. They do not establish physical keyboard-input acceptance, real embedding quality, a full launcher-controller run, external-reader positioning or long-term stability. Remaining GUL-405 work and GUL-406's parked state are unchanged. Roll back this repair commit to restore the old test harness; reverting PR624 removes the original OCR-preview feature.

Final validation: the focused coverage command exits **0**, with **one method / two parameter cases passing**, **329.29 seconds** total command wall time, **278.20 seconds** compilation, **307.22 seconds** preparation/discovery, and **11.65 seconds** test execution. There were **no coverage/test retries**. The relocated private APFS build-cache clone required rebuilding; no passing test result was cached or reused for this method. The new harness's added/modified executable lines are **83/83** covered. Application and shared-media production additions in this repair are **0/0**, so a new production coverage percentage is not applicable. The original slice's **46/46 application** and **54/54 shared-media** line coverage remain reused evidence, not a measurement attributed to this command. See `harness-coverage.json`, compressed LCOV/profile/log, and `provenance.json` for the denominators and fingerprints.

All eight fresh preview captures pass the region predicate. The dark file-entry highlighted image has one recognized code region, 265 ink pixels and 601 yellow pixels inside its padded bounds; the unlocated fallback has 346 ink pixels and no yellow pixels. All four unchanged historical highlighted captures also pass. The erased-image negative control has no recognized code, ink or yellow pixels. Strict SwiftLint passes for both modified/added test files with zero violations, and `git diff --check` passes.

Self-review covered the persistent-hit-to-production-view chain, image-only cropping and backing-density conversion, fallbacks, the adversarial blank control, MainActor/exclusive UI isolation, panel cleanup, localization restoration, file/version replacement, cancellation/permission preservation, and documentation consistency. The new assertions examine exported PNG bytes rather than the source raster or left-hand result text. No private input files, production decoding path or external resources were introduced. The only lint issue introduced during implementation was an overlong snapshot method; it was shortened before test-source compilation. No functional failures remained after validation. The exact historical viewing discrepancy is still unknown and is not presented as a fixed product bug.
