# Stage 4 package evidence preflight

This increment adds a repeatable, read-only prerequisite for the existing seven-row acceptance checklist. It does not run a recording, move microphone ownership, sign an app, inspect a keychain, download resources or launch bundled code. No real signed release package was supplied or certified by this run.

## Use on a designated private package

From the repository root, supply the intended release architecture and full source commit:

```sh
python3 scripts/stage4_preflight.py \
  --app ./private-test/Typeflux.app \
  --architecture arm64 \
  --source-commit FULL_40_CHARACTER_COMMIT > ./stage4-package.json
```

The command checks the bundle identity, main executable, microphone purpose declaration, executable inference/media helpers and nonempty Hub tokenizer resources at the same helper-relative location used by `copy_inference_helper.sh`. It also requires the semantic helper for arm64/universal, matching `build_release.sh`; Intel packages do not require that runtime. Missing/invalid members, symlinks in audited paths, invalid plists and observed file changes produce structured failure and exit 1. Output contains relative member paths, lengths and SHA-256 hashes, without the supplied absolute package path. Hashing is streamed with explicit file/resource bounds. Normal successful reports are deterministic for the same stable package and inputs.

A successful structural result always has `stage4_accepted: false` and all seven manual gates `not_verified`. The architecture is explicitly a **requested** architecture; it is not inferred from a file name or executable bit. The source commit is an operator claim, not verified build provenance. Hashes identify inputs but establish neither code signatures nor notarization. Use the existing `audit_macho_minos.sh` for actual Mach-O architecture/minimum-OS checks and `verify_release_artifacts.sh` for the separately authorized release signature/Gatekeeper/stapler checks. These existing tools were not invoked here. The preflight neither replaces them nor catches native capture faults.

The tool operates on a stable, private bundle. Symlink refusal and before/after metadata checks are useful diagnostics, not a concurrent filesystem transaction or an authorization grant. Already-running code, TCC state, hardware ownership, framework scratch memory and runtime behavior are outside its scope.

## Validation

Baseline `be6de6b9c07891639d79f41c3058b7422bf7d5c1` was read immediately after the clean branch was created from fetched main. No Swift, helper ABI, package-building/signing behavior or UI layout changed. No Swift rebuild/profile reuse, screenshot or copied-helper runtime probe was applicable to this read-only Python tool.

Twelve selected methods passed: ten new `test_stage4_preflight` methods plus only `test_missing_helper_or_resources_cannot_produce_a_partial_install` from each existing inference/media packaging suite. All selected bodies and copy scripts were read before execution. Fixtures use private synthetic files and fake executable bytes; no fake or actual helper is executed. Existing copy-script regressions copy files only; the Ruby/Xcode project tests and unrelated script suites were not selected.

New tests cover deterministic member hashes and no mutation, Intel versus arm/universal requirements, missing/nonexecutable/wrong-type members, identity and privacy purpose refusal, root/member/resource symlinks, empty/oversized input, empty resources, explicit architecture/commit validation, changed-file refusal, structured CLI success/failure and malformed plists. Each test removes its private fixture directory; no background task or subprocess remains.

Both functional passes were **12/12 successful**. The first validation command failed only after the tests, while sorting Python 3.14's `None` executable pseudo-line in the workspace coverage reporter. Only that reporter was corrected; the same exact focused scope was repeated, with no production/test edits or assertion/timeout relaxation. Final command wall time was 0.397 seconds. This was a report-runner correction, not a functional test failure.

Python stdlib `trace` records **100/106 = 94.34% statement-line coverage** of the wholly new tool, above the current 70% threshold. The conservative denominator retains synthetic line 0 and excludes `None` pseudo-lines; imports/declarations count. This is not Swift LLVM, branch, whole-project or real-package coverage. No extra tests were added to pursue a higher percentage. The exact input hashes, excluded lines and runner history are in `stage4-preflight-results.json`; product/test/copy-script input hashes matched before and after final execution.

A focused reproduction of the new tests is:

```sh
python3 -m unittest discover -s scripts/tests -p test_stage4_preflight.py -v
```

Stage 4 still requires a designated signed package and test Mac, then the existing explicit permission/device/performance procedures. No synthetic report turns those seven unexecuted rows into passes. The completed resource/consumer work is not reopened by this prerequisite tool.
