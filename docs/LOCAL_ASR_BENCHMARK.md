# Local ASR Benchmark

`scripts/local_asr_benchmark.py` runs a local-only mixed Chinese/English ASR benchmark around the existing `Typeflux batch-wav` command.

The harness benchmarks these local models when their prepared assets are already present:

- SenseVoice Small
- Qwen3-ASR 0.6B int8
- WhisperKit Medium

Missing assets are reported as skipped models in the JSON and Markdown reports. The harness disables local auto-setup for the benchmark process so a run does not download missing models or touch remote STT providers.

## Manifest

Use `docs/local-asr-benchmark-manifest.json` as the starting format. Each sample needs:

- `id`: stable sample identifier
- `audioFile`: WAV path relative to the manifest directory, or `--audio-root`
- `reference`: expected transcript
- `expectedTerms`: English/product/code terms for recall scoring
- `protectedTerms`: optional per-sample exact-match terms; when omitted, the manifest-level `protectedTerms` list is used

The checked-in sample manifest covers product names, acronyms, code terms, and short ordinary mixed Chinese/English sentences.

## Run

Prepare matching WAV files, then run:

```bash
python3 scripts/local_asr_benchmark.py \
  --manifest docs/local-asr-benchmark-manifest.json \
  --audio-root docs \
  --output-dir reports/local-asr-benchmark
```

Reports are written to:

- `reports/local-asr-benchmark/report.json`
- `reports/local-asr-benchmark/summary.md`

Use `--typeflux-bin /path/to/Typeflux` to benchmark a prebuilt executable instead of `swift run`.

## Metrics

The machine-readable report includes:

- whole-transcript Levenshtein distance and normalized distance ratio
- expected English/token recall
- protected term exact-match score
- per-sample and average runtime
- model disk footprint
- skip diagnostics for unavailable local assets

Run the metric self-test with:

```bash
python3 scripts/local_asr_benchmark.py --self-test
```
