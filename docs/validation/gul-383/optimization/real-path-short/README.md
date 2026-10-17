# GUL-405 real model and native input short verification

This slice adds validation tools and evidence only. No production source, settings default, model recipe, parser or ranking parameter changed. Read `scope.md` for all 17 merged slices and remaining core work.

The tools link a new Swift executable against the accepted PR646 Debug objects, including existing native test fixtures. The accepted application and helper are not rebuilt. `cached-input-reconciliation.json` matches 2,431 cached source/test/tool inputs and discloses 14 main-only Ask tool approval/localization differences. Relevant search, reader and media files match. `reused-objects.json` records all reused object digests. This is not a full-tree current-main rebuild/test claim.

Actual text weights and projector are checked against their pinned SHA-256 before private APFS clones are made. The app's production verifier also runs. No network transfer is requested. Inputs are existing synthetic DOCX, scanned invoice, screenshot and short MOV fixtures, copied into an owned private scope. The successful narrower run uses DOCX/PDF only. The real FSEvents watcher observes file writes; there is no manual index reconciliation or fixed-vector injection.

`real-path.json` records service queries, native NSTextView edits through the mixed launcher and Files plugin, actual hit snippets/IDs/pages/versions, an observed file write, separately reopened persistent queries, and an optional 300-second document indexing/input window. Input latency ends at forced layout plus accessibility observation. The separate existing own-window probe measures generated events to native handlers and WindowServer frames. Neither boundary establishes physical HID-to-monitor search latency.

The service uses isolated defaults and scope. Access is allowed only for this synthetic scope; low-power/query thermal callbacks are controlled while the enabled production work budget observes real memory/thermal state. The native fixture keeps shared authentication away from the user's Keychain and disables the user's shared file index. Language/accessibility settings are restored, writers/helpers are stopped and joined, the defaults domain is removed, then the parent removes only its own private root. The independent response probe is also joined. Ordinary user models/indexes are not cleared.

## Commands

From the repository root, pass the existing private cache locations explicitly; do not download assets:

```sh
python3 docs/validation/gul-383/optimization/real-path-short/build_probe.py --cache-checkout <accepted-pr646-checkout>
python3 docs/validation/gul-383/optimization/ranking-scale/rework_resource_runner.py --output docs/validation/gul-383/optimization/real-path-short/resources -- python3 docs/validation/gul-383/optimization/real-path-short/run_probe.py --cache-checkout <accepted-pr646-checkout> --model-assets <pinned-assets> --documents-only --resource-seconds 300 --native-probe <existing-native-probe>
python3 docs/validation/gul-383/optimization/real-path-short/reconcile.py
```

The accepted cache must retain matching objects, modules, generated link metadata and resource bundles. `build_probe.py` refuses changed cached sources/objects and relevant main differences. Runtime output and object caches remain local; no cached weights or executable is included in this delivery. Reports use path tokens for runtime-local locations.

## Failures and limits

The first probe-only compile used a nonexistent service method; its 13.38-second failure remains. The first executable attempt placed fixtures below `.build`; the correct hidden-path policy excluded them, and native search timed out. Its complete raw 50.99-second wrapper run remains in `first-hidden-scope-failure/`. The private root was moved outside hidden paths and an empty-index check was added.

The next all-modality attempt reached persisted Office/PDF vectors but did not finish screenshot/media indexing within its 240-second wait. The full 248.59-second command and resource record remain in `media-startup-timeout/`. The owned media helper was observed in uninterruptible startup with little accumulated CPU. Memory pressure/swap were present, but no causal diagnosis was established. That attempt used the testing default budget; the narrower final tool explicitly enables the production budget. A matching source reconstruction is retained for the timed-out binary; the first hidden-fixture source is reconstructed without an original source-digest claim. `tool-history.json` also discloses an overwritten intermediate compile/link command record. No historical failure is turned into a pass.

The successful document scope proves only the cases it records. Whole fixed-cohort new-version quality, new screenshot/media semantics, Release/large-scale performance and long thermal stability are not established. Changed production executable lines are application 0/0, file helper 0/0 and media runtime 0/0: coverage is not applicable to this evidence-only slice. The accepted >=70% production coverage is reused, with no artificial mirror tests or repeated old coverage run.
