#!/usr/bin/env python3
"""Collect final matrix cells and recompute quantiles without dropping failed queries."""
import json
import math
import shutil
from collections import defaultdict
from pathlib import Path

folder = Path(__file__).parent.resolve()
root = folder.parents[4]
baseline = root / '.build/baseline-code/docs/validation/gul-383/optimization/ranking-scale'
run = json.loads((folder / 'matrix-run-final.json').read_text())


def quantiles(values):
    values = sorted(x for x in values if x is not None)
    return {str(p): values[math.ceil((len(values) - 1) * p)] if values else None
            for p in [.5, .95, .99, 1]}


cells = []
groups = []
for cell in run['cells']:
    label, size, tag, mode = (cell[x] for x in ['label', 'size', 'tag', 'mode'])
    name = f'native-{label}-{size}-{tag}.json' if mode == 'native' else f'contention-{label}-{tag}-{size}.json'
    runner = f'rework-run-{mode}-{label}-{size}-{tag}'
    if label == 'before' and baseline.is_dir():
        for pattern in [name, name.replace('.json', '.partial.json'), runner + '.json', runner + '.log']:
            origin = baseline / pattern
            if origin.is_file():
                shutil.copy2(origin, folder / pattern)
    path = folder / name
    partial = folder / name.replace('.json', '.partial.json')
    report = json.loads((path if path.exists() else partial).read_text()) if path.exists() or partial.exists() else {}
    rows = report.get('rows', [])
    cells.append(dict(**cell, report=path.name if path.exists() else partial.name if partial.exists() else None,
                      complete=bool(report.get('complete')), rows=len(rows), failed_body_samples=report.get('failed_body_samples'),
                      stage=report.get('stage'), command_report=runner + '.json'))
    by_group = defaultdict(list)
    for row in rows:
        by_group[(row['entry'], row['scenario'])].append(row)
    for (entry, scenario), selected in sorted(by_group.items()):
        is_voice = scenario.startswith('voice-')
        missing = sum(x.get('input_to_draw_ms') is None for x in selected) if not is_voice else 0
        metric = 'asr_ms' if is_voice else 'input_to_draw_ms'
        quantile = quantiles(x.get(metric) for x in selected)
        limit = None
        if label == 'after' and size == 100000:
            if scenario in ['fts-cache', 'index-writer', 'fts-real-index']:
                limit = 100
            elif scenario in ['hot-new-semantic', 'semantic-real-index']:
                limit = 300
        groups.append(dict(label=label, chunks=size, mode=mode, tag=tag, entry=entry, scenario=scenario,
                           noise='actual-geology-embedding' if cell.get('real') else 'synthetic-controlled',
                           n=len(selected), missing_body=missing,
                           draw_or_asr_ms=quantile,
                           publish_ms=quantiles(x.get('input_to_publish_ms') for x in selected),
                           main_actor_gap_ms=quantiles(x.get('main_actor_max_timer_gap_ms') for x in selected),
                           fts_during_voice_ms=quantiles(x.get('fts_during_voice_ms') for x in selected),
                           voice_missing_transcripts=sum(not x.get('transcript_nonempty', False) for x in selected) if is_voice else None,
                           voice_missing_fts=sum(not x.get('fts_found_body', False) for x in selected) if is_voice else None,
                           hard_100k_limit_ms=limit,
                           meets_limit=(bool(report.get('complete')) and not cell['exit_code'] and not missing and quantile['0.95'] <= limit)
                               if limit is not None and quantile['0.95'] is not None else None,
                           report=name))
result = dict(scope=run['scope'], source_commit='1265fea7be1faa842cf99218e09637798d7b09da',
              known_agent_interference='Report analysis and Matplotlib font-cache/plot generation overlapped the first 10k baseline cell. Small report analyses also occurred during later cells. No owned Swift build or second UI suite overlapped. The sampler separately records external compiler/test processes; it does not account for other evidence-analysis Python tasks. Shared-host timings are not isolated causal estimates. Helper basenames combine query and index roles in resource samples; no per-role CPU/IO claim is made.',
              expected_cells=24, recorded_cells=len(cells),
              complete=len(cells) == 24 and all(x['complete'] for x in cells),
              all_commands_pass= len(cells) == 24 and all(x['exit_code'] == 0 for x in cells),
              quantiles='ceil((n-1)*p); missing bodies remain failures and are never assigned zero latency',
              cold='Fresh service/helper, OS/model/shader caches may stay warm; reopen and readiness occur outside timed edit.',
              gates='100k hot body100ms / real uncached hot semantic300ms only. Writer and real-index rows report the same hot limits under their stated load. No cold or million-scale universal limit is invented.',
              cells=cells, groups=groups)
(folder / 'final-matrix-summary.json').write_text(json.dumps(result, indent=2) + '\n')
lines = ['Final-source query matrix. Production source `1265fea7`; baseline `262135bc`, current main base `ceeaaef5`. Full command timings and failures are in `matrix-run-final.json` and per-cell command reports. The host is shared, not isolated.', '',
         'Native input is an actual committed NSTextView edit; drawing uses actual layout/display plus accessibility, not a WindowServer result fence. Scale fixtures contain two files with repeated chunks. Cold readiness/reopening is excluded from the timed edit, and OS caches may remain warm. Real-noise rows repeat an actual geology embedding. Actual contention adds 512 real documents and production inference; voice calls actual SenseVoice through the production busy boundary without microphone/hotkey capture.', '',
         f"Recorded cells: {len(cells)}/24. Complete reports: {sum(x['complete'] for x in cells)}. Failed commands: {sum(x['exit_code'] != 0 for x in cells)}. Missing/failed bodies are retained in each denominator.", '',
         '| Chunks | Build | Entry | Scenario | Noise | n / missing | p50 / p95 / p99 / max ms | 100k hot limit |',
         '| --- | --- | --- | --- | --- | --- | --- | --- |']
for group in groups:
    q = group['draw_or_asr_ms']
    text = ' / '.join(f'{q[str(p)]:.2f}' if q[str(p)] is not None else 'missing' for p in [.5,.95,.99,1])
    gate = 'reported separately' if group['hard_100k_limit_ms'] is None else f"{group['hard_100k_limit_ms']} ms: {'pass' if group['meets_limit'] else 'FAIL'}"
    lines.append(f"| {group['chunks']} | {group['label']} | {group['entry']} | {group['scenario']} | {group['noise']} | {group['n']} / {group['missing_body']} | {text} | {gate} |")
lines += ['', 'Voice rows show ASR completion, not body drawing. FTS-during-voice, observed batch counters, transcript failures and per-sample timing remain in the JSON. An observer-active interval includes worker startup/interruption; it is not a hardware inference-kernel trace. Main-thread gaps include accessibility/polling work and cannot replace desktop-response evidence.', '',
          'Every per-cell resource folder retains adjacent-process CPU/IO inputs and external compiler/test presence. Summed RSS double-counts shared pages. Privileged energy metrics and physical monitor/HID latency are unavailable. This matrix does not establish the original user incident root cause.']
(folder / 'final-matrix-results.md').write_text('\n'.join(lines) + '\n')
print(json.dumps(dict(cells=len(cells), complete=result['complete'], groups=len(groups))))
