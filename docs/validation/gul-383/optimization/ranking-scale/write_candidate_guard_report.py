#!/usr/bin/env python3
"""Keep the final allocation optimization separate from the primary matrix."""
import json
import math
from pathlib import Path

HERE = Path(__file__).parent


def quantiles(values):
    values = sorted(math.inf if value is None else value for value in values)
    result = dict(n=len(values), unavailable=sum(not math.isfinite(value) for value in values))
    for percentile in [50, 95, 99]:
        value = values[max(0, math.ceil(percentile / 100 * len(values)) - 1)] if values else math.inf
        result[f'p{percentile}'] = value if math.isfinite(value) else None
    return result


assert quantiles([1, None, 2]) == dict(n=3, unavailable=1, p50=2, p95=None, p99=None)


def cell(value):
    result = ' / '.join('unbounded' if value[f'p{p}'] is None else f"{value[f'p{p}']:.2f}" for p in [50, 95, 99])
    return result + f" (n={value['n']}, unavailable={value['unavailable']})"


lines = ['# Final candidate-allocation probe', '',
         'The complete cold/cache/writer/real-index matrix predates this final optimization and remains in performance-summary.md. This probe uses the current source-hashes.json. It repeats only the declared real-model hot-new-semantic scenario at all three chunk scales, with unchanged thresholds and no sample removal. Before is the GUL-403 baseline; intermediate is source-hashes-before-candidate-guard.json. The final guard rejects losing same-file candidates before allocating their hit/name, and single-class calibration returns zero earlier. Full 400-query ranking JSON parity is recorded separately.', '',
         'Same pinned model and shared M4/16 GiB host. Two source facts are repeated to the desired chunk count; these are not representative million-file data. Input and drawing have the same controlled native-editor/layout/accessibility boundary as the primary matrix. These measurements do not cover physical pointer input, a compositor fence or an installed app. No resource-controller implementation is implied.', '',
         'Cells are draw p50 / p95 / p99 in milliseconds.', '',
         '| Chunks / entry | Before | Intermediate | Final allocation guard |',
         '| --- | --- | --- | --- |']
reports = []
for size in [10000, 100000, 1000000]:
    stems = [f'native-before-{size}-real-noise', f'native-after-{size}-real-noise',
             f'native-after-{size}-candidate-guard']
    variants = [json.loads((HERE / (stem + '.json')).read_text()) for stem in stems]
    runs = [json.loads((HERE / ('run-' + stem + '.json')).read_text()) for stem in stems]
    for name in ['mixed', 'file-mode']:
        qs = [quantiles([row['input_to_draw_ms'] for row in variant['rows'] if row['entry'] == name])
              for variant in variants]
        q = qs[-1]
        passed = q['p95'] is not None and q['p95'] <= 300 and q['unavailable'] == 0 and runs[-1]['exit_code'] == 0
        reports.append(dict(chunks=size, entry=name, before=qs[0], intermediate=qs[1], final=qs[2],
                            final_test_exit_code=runs[-1]['exit_code'], target_p95_ms=300, passed=passed))
        lines.append(f'| {size:,}/{name} | ' + ' | '.join(cell(value) for value in qs) + ' |')
    resources = []
    for run in runs:
        peaks = {}
        for sample in run['samples']:
            for process, values in sample['rss_bytes'].items():
                peaks[process] = max(peaks.get(process, 0), sum(values))
        resources.append(dict(wall_seconds=run['wall_seconds'], exit_code=run['exit_code'],
                              peak_rss_bytes_by_process_name=peaks,
                              external_cpu_peak=max((s['external_compiler_or_test_cpu_percent'] for s in run['samples']), default=0)))
    reports.append(dict(chunks=size, resources_before_intermediate_final=resources,
                        final_binary_sha256=runs[-1]['test_binary_sha256_after_command'],
                        final_production_sources_sha256=runs[-1]['production_sources_sha256_at_start']))
lines += ['', 'The 300 ms observation applies only to this hot scenario. Cold first-body, real-index contention, per-group MRR and the new background-resource requirements remain separate unresolved gates. RSS/process maps, host swap/free disk and external compiler activity remain in each raw run report. Command wall includes compilation/setup; query timers exclude those stages.', '']
(HERE / 'candidate-guard-summary.md').write_text('\n'.join(lines))
(HERE / 'candidate-guard-summary.json').write_text(json.dumps(dict(scope='Final-source hot real-model supplement only; no replacement of the primary matrix.', reports=reports), indent=2)+'\n')
print('Wrote candidate-guard-summary.md/json')
