#!/usr/bin/env python3
"""Render retained matrix summaries without dropping unavailable body samples."""
import json
from pathlib import Path

HERE = Path(__file__).parent
raw = json.loads((HERE / 'summary.json').read_text())
lines = ['# Release scale comparison', '',
         'Primary matrix: the after variant is source-hashes-before-candidate-guard.json. Current-source ranking parity and real-model hot probes are separate in candidate-guard-summary.md; this table is not a full final-binary matrix. Apple M4 / 16 GiB, pinned Q8 weights, Release. Native input means a committed NSTextView edit; drawing means forced layout/display plus rendered accessibility observation, not a compositor fence. Filename search returns no hits and surrounding conversation/app providers use the existing test fixture. This isolates body retrieval and does not measure installed-app startup or physical event delivery. The host is shared.', '',
         'Each cell is p50 / p95 / p99 in milliseconds. Cold has 10 samples per entry; warm has 100 at 10k/100k and 20 at 1m; semantic-cache reuse excludes its separately reported first fill (99 or 19 reuse samples). The 1m p95/p99 estimates have limited precision. Terminal queries without the expected body remain in the denominator as unbounded latency. `unbounded` does not mean zero. Complete capture does not imply passing tests.', '']

def qcell(q):
    if not q:
        return 'missing'
    values = ['unbounded' if q.get(f'p{p}') is None else f"{q[f'p{p}']:.2f}" for p in [50, 95, 99]]
    return ' / '.join(values) + f" (n={q['n']}, unavailable={q.get('n_missing', 0)})"

def data(label, size):
    return raw['scale'].get(label, {}).get(str(size), {})

def metric(label, size, group, name):
    return data(label, size).get('groups', {}).get(group, {}).get(name)

def entry(meta, name, key):
    return next((value for value in meta.get(key, []) if value['entry'] == name), {})

for size in [10000, 100000, 1000000]:
    lines += [f'## Initial {size:,} chunks', '',
              'The controlled base has two files: one real winning document vector and repeated orthogonal noise. The real-model supplement instead repeats an actual geology embedding with matching stored text and FTS terms. This still has only two independent source documents. Real background indexing grows the corpus during contention; end counts are listed below. These are chunk-scale stress results, not million-file or representative-corpus quality evidence.', '',
              '| Entry / scenario | Before | After |', '| --- | --- | --- |']
    for name in ['mixed', 'file-mode']:
        for scenario in ['cold', 'cold-fts', 'fts-cache', 'semantic-cache-fill', 'semantic-cache', 'hot-new-semantic', 'real-model-hot-new-semantic', 'index-writer', 'fts-real-index', 'semantic-real-index']:
            group = name + '/' + scenario
            lines.append(f"| {group} | {qcell(metric('before', size, group, 'input_to_draw_ms'))} | {qcell(metric('after', size, group, 'input_to_draw_ms'))} |")
    lines += ['', '### Resources and command wall time', '',
              'RSS is the sampled resident size by descendant executable name; sums double-count shared pages. `swiftpm-testing-helper` hosts the app under test, while `Typeflux` includes filesystem-worker children. The complete process maps remain in summary.json. External CPU peaks cover the entire command, including preparation; older reports lack an anchor for per-query alignment. They are not proof of query-specific contention or an isolated causal comparison.', '',
              '| Case | Test exit before → after | Command wall seconds before → after | Peak RSS MiB before → after | External compiler/test CPU peak before → after |', '| --- | --- | --- | --- | --- |']
    for mode in ['native', 'contention', 'cold-fts', 'real-noise']:
        reports = [data(label, size).get('resources', {}).get(mode, {}) for label in ['before', 'after']]
        wall = ' → '.join(f"{report.get('wall_seconds', 0):.2f}" for report in reports)
        rss = ' → '.join('; '.join(f'{name}={value/1048576:.1f}' for name, value in report.get('peak_rss_bytes_by_process_name', {}).items()) or 'missing' for report in reports)
        cpu = ' → '.join(f"{report.get('external_compiler_or_test_cpu_peak', 0):.1f}%" for report in reports)
        codes = ' → '.join(str(report.get('exit_code', 'missing')) for report in reports)
        lines.append(f'| {mode} | {codes} | {wall} | {rss} | {cpu} |')
    lines += ['', '| Entry | Native index disk MiB before → after | Contention index disk MiB before → after | Contention chunks at end before → after | Encoded texts / active inference second before → after | Encoded texts / observed wall second before → after |', '| --- | --- | --- | --- | --- | --- |']
    for name in ['mixed', 'file-mode']:
        native = [entry(data(label, size).get('metadata', {}).get('native', {}), name, 'corpus') for label in ['before', 'after']]
        contention = [entry(data(label, size).get('metadata', {}).get('contention', {}), name, 'entries') for label in ['before', 'after']]
        ndisk = ' → '.join(f"{value.get('disk_bytes', 0)/1048576:.2f}" for value in native)
        cdisk = ' → '.join(f"{value.get('disk_bytes', 0)/1048576:.2f}" for value in contention)
        counts = ' → '.join(str(value.get('chunks_at_end', 'missing')) for value in contention)
        active = ' → '.join(f"{value.get('successful_texts_per_active_inference_second', 0):.2f}" for value in contention)
        wall = ' → '.join(f"{value.get('successful_texts_per_wall_second', 0):.2f}" for value in contention)
        lines.append(f'| {name} | {ndisk} | {cdisk} | {counts} | {active} | {wall} |')
    lines += ['', 'Background throughput counts successfully encoded texts during the observation window, not completed files. There are 512 synthetic geological documents, each 54,400 UTF-8 bytes. Native writer contention is a separate synthetic writer; real-index contention uses the production document queue and helper.', '',
              '### Actual ASR contention', '',
              'Each condition has 10 real SenseVoice transcriptions per entry from the same generated 5.5693125-second WAV. Foreground busy is driven at the production service boundary; this is not microphone/hotkey latency. FTS during voice is service completion, not a native draw boundary.', '',
              '| Entry / condition | ASR before | ASR after | FTS during voice before | FTS during voice after |', '| --- | --- | --- | --- | --- |']
    for name in ['mixed', 'file-mode']:
        for condition in ['voice-idle', 'voice-preempt-index']:
            group = name + '/' + condition
            cells = [qcell(metric(label, size, group, key)) for key in ['asr_ms', 'fts_during_voice_ms'] for label in ['before', 'after']]
            lines.append('| ' + group + ' | ' + ' | '.join(cells) + ' |')
    lines.append('')

checks = []
for size in [10000, 100000, 1000000]:
    conditions = [('hot-new-semantic', 300), ('real-model-hot-new-semantic', 300), ('semantic-real-index', 300)]
    if size == 100000:
        conditions = [('cold-fts', 100), ('fts-cache', 100), ('index-writer', 100), ('fts-real-index', 100)] + conditions
    for name, scenario, limit in [(name, scenario, limit) for name in ['mixed', 'file-mode'] for scenario, limit in conditions]:
        q = metric('after', size, name + '/' + scenario, 'input_to_draw_ms')
        actual = q.get('p95') if q else None
        mode = 'cold-fts' if scenario == 'cold-fts' else ('contention' if scenario.endswith('real-index') else 'native')
        if scenario.startswith('real-model-'):
            mode = 'real-noise'
        code = data('after', size).get('resources', {}).get(mode, {}).get('exit_code')
        latency_passed = actual is not None and actual <= limit
        checks.append(dict(chunks=size, entry=name, scenario=scenario, target_p95_ms=limit, actual_p95_ms=actual,
                           n=q.get('n', 0) if q else 0, unavailable=q.get('n_missing', 0) if q else 0,
                           test_exit_code=code, latency_passed=latency_passed,
                           passed=latency_passed and q.get('n_missing', 0) == 0 and code == 0))
lines += ['## p95 target observations', '',
          'The 100 ms first-body target is shown at 100k for actual cold FTS as well as warm conditions; a warm pass is not a blanket cold pass. The warm 300 ms noncached semantic target is shown at all three scales, including real-index contention. The original cold scenario is semantic-only and is reported separately. A condition is marked met only if its p95 meets the threshold, no body is missing and its whole benchmark returns zero. Other assertions and retained failed attempts still require review even when an observed p95 meets its threshold.', '',
          '| Scale / entry / condition | p95 ms | Target ms | Result |', '| --- | --- | --- | --- |']
for check in checks:
    observed = 'unbounded/missing' if check['actual_p95_ms'] is None else f"{check['actual_p95_ms']:.2f}"
    lines.append(f"| {check['chunks']:,}/{check['entry']}/{check['scenario']} | {observed} | {check['target_p95_ms']} | {'met' if check['passed'] else 'not met'} |")
lines += ['', 'Quality tradeoffs, the original oracle gaps, Float16 ordering differences and retained failed/retried runs are documented in quality-summary.md, quantization.json and README.md. These tables do not establish general corpus or per-group MRR non-regression.', '']
(HERE / 'performance-summary.md').write_text('\n'.join(lines))
(HERE / 'latency-targets.json').write_text(json.dumps(dict(production_source_manifest='source-hashes-before-candidate-guard.json', scope='Observed pre-candidate-guard after draw p95: body at 100k; warm noncached semantic at all scales including real-index contention. Cold body target is kept visible; no thresholds are lowered.', checks=checks), indent=2)+'\n')
print('Wrote performance-summary.md and latency-targets.json')
