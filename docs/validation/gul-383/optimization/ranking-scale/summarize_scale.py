#!/usr/bin/env python3
"""Summarize retained per-query rows. No sample removal except documented cache fill."""
import json
import math
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).parent

def quantiles(values):
    # A terminal query without a body is unbounded for first-body latency. It stays
    # in the denominator and sorts above all observed times; JSON null denotes that quantile.
    values = sorted(float('inf') if value is None else value for value in values)
    result = dict(n=len(values), n_missing=sum(not math.isfinite(value) for value in values))
    for percent in [50, 95, 99]:
        value = values[max(0, math.ceil(percent / 100 * len(values)) - 1)] if values else float('inf')
        result[f'p{percent}'] = value if math.isfinite(value) else None
    return result

assert quantiles([1, None, 2]) == dict(n=3, n_missing=1, p50=2, p95=None, p99=None)
assert quantiles(list(range(1, 101)))['p95'] == 95

reports = {}
for label in ['before', 'after']:
    scales = {}
    for size in [10000, 100000, 1000000]:
        groups = defaultdict(lambda: defaultdict(list))
        metadata = {}
        for mode, name in [('native', 'native'), ('contention', 'contention'), ('cold-fts', 'native'), ('real-noise', 'native')]:
            suffix = '-' + mode if mode in ['cold-fts', 'real-noise'] else ''
            source = HERE / f'{name}-{label}-{size}{suffix}.json'
            if not source.exists():
                continue
            report = json.loads(source.read_text())
            metadata[mode] = {key:value for key,value in report.items() if key != 'rows'}
            metadata[mode]['terminal_without_body_samples'] = sum(row.get('outcome') == 'terminal-without-body' for row in report['rows'])
            for entry in metadata[mode].get('entries', []):
                intervals = entry.get('index_intervals', [])
                active_seconds = sum(end-start for start,end in intervals)
                if intervals and active_seconds > 0:
                    entry['successful_texts_per_active_inference_second'] = entry['successfully_embedded_texts'] / active_seconds
                    entry['successful_texts_per_wall_second'] = entry['successfully_embedded_texts'] / (intervals[-1][1]-intervals[0][0])
            for row in report['rows']:
                # Round zero fills the semantic cache, and remains in the raw artifact.
                scenario = row['scenario']
                if mode == 'real-noise':
                    scenario = 'real-model-' + scenario
                if scenario == 'semantic-cache' and row['round'] == 0:
                    scenario = 'semantic-cache-fill'
                key = row['entry'] + '/' + scenario
                for metric in ['input_to_publish_ms', 'input_to_draw_ms', 'complete_ms', 'main_actor_max_timer_gap_ms', 'asr_ms', 'fts_during_voice_ms']:
                    if metric in row:
                        groups[key][metric].append(row[metric])
        resources = {}
        for mode in ['native', 'contention', 'cold-fts', 'real-noise']:
            stem = f'native-{label}-{size}-{mode}' if mode in ['cold-fts', 'real-noise'] else f'{mode}-{label}-{size}'
            file = HERE / f'run-{stem}.json'
            if file.exists():
                run = json.loads(file.read_text()); rss = defaultdict(list)
                for sample in run['samples']:
                    for process, values in sample['rss_bytes'].items():
                        rss[process].append(sum(values))
                resources[mode] = dict(exit_code=run['exit_code'], wall_seconds=run['wall_seconds'],
                    peak_rss_bytes_by_process_name={name:max(values) for name,values in rss.items()},
                    external_compiler_or_test_cpu_peak=max((s.get('external_compiler_or_test_cpu_percent', 0) for s in run['samples']), default=0))
        if groups:
            scales[size] = dict(groups={key:{metric:quantiles(values) for metric,values in metrics.items()} for key,metrics in groups.items()}, metadata=metadata, resources=resources)
    reports[label] = scales
quality = {}
non_row_reports = []
for source in sorted(HERE.glob('ranking-*.json')):
    raw = json.loads(source.read_text()); groups = defaultdict(list)
    if not isinstance(raw.get('rows'), list):
        non_row_reports.append(source.name)
        continue
    for row in raw['rows']:
        groups[row['group']].append(row)
    quality[source.stem] = {key:dict(n=len(rows), recall_at_5=sum(r['rank'] is not None for r in rows)/len(rows),
        mrr=sum(1/r['rank'] if r['rank'] else 0 for r in rows)/len(rows),
        false_positive_rate=sum(bool(r['hits']) and not r['expected'] for r in rows)/len(rows),
        location_at_5=sum(bool(r['location_correct']) for r in rows)/len(rows),
        location_correct_given_retrieved=sum(bool(r['location_correct']) for r in rows)/max(1, sum(r['rank'] is not None for r in rows))) for key,rows in groups.items()}
output = dict(quantiles='Empirical nearest-rank; cold n=10 per entry, warm n=100 at 10k/100k and n=20 at 1m except semantic cache reuse n=99/19. The first aborted 1m run used n=100; its partial rows are separate. No outlier trimming. Missing body samples remain in the quantile denominator as unbounded (JSON null). The initial one-cold-sample run is separate.', scale=reports, quality=quality, non_row_quality_reports=non_row_reports,
              limitations='Controlled two-file chunk load, real query/background embeddings and permission/UI code. Layout/display plus accessibility observation is not a compositor fence. ASR measures a generated WAV through the real transcriber with the service busy boundary driven directly.')
(HERE / 'summary.json').write_text(json.dumps(output, indent=2)+'\n')
for label, scales in reports.items():
    for size, data in scales.items():
        print(label, size, {key:{metric:(round(q['p95'], 2) if q['p95'] is not None else 'unbounded') for metric,q in metrics.items() if metric in ['input_to_draw_ms', 'asr_ms']} for key,metrics in data['groups'].items()})
