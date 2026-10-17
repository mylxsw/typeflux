#!/usr/bin/env python3
"""Recompute the bounded document/native summary from retained raw reports, including missing data."""
import gzip
import json
import math
from pathlib import Path

out = Path(__file__).resolve().parent


def read(name):
    path = out / name
    if path.exists():
        return json.loads(path.read_text())
    with gzip.open(str(path) + '.gz', 'rt') as stream:
        return json.load(stream)


def quantile(values):
    values = sorted(v for v in values if isinstance(v, (int, float)) and math.isfinite(v))
    if not values:
        return {'n': 0}
    return {'n': len(values), **{str(q): values[min(len(values)-1, int(len(values)*q))] for q in [.5, .95, .99, 1]}}


app = read('real-path.json')
native = read('native-response.json')
resources = read('resources/resources.json')
assert app['complete'] and app['cleaned_up'] and app['budget_enabled']
assert read('runtime-command.json')['exit_code'] == 0
assert read('artifact-integrity.json')['binary_and_source_still_match_tested_probe']
assert read('gul404-artifact-reuse.json')['all_matched']
assert {row['entry'] for row in app['native']} == {'mixed', 'files'}
assert all(row['found'] for row in app['queries'])
assert app['file_event']['hits'] and app['reopened_real_model_hits']
proof = read('live-persisted-vector-proof.json')
assert any(row['name'] == 'event.txt' and row['vector_bytes'] == 3072 and row['vector_sha256'] for row in proof['rows'])
rows, queries, samples = native['inputs'], app['resource_rows'], resources['samples']
assert native['complete'] and native['duration_seconds'] >= 300 and app['resource_duration_seconds'] >= 300
assert [row['id'] for row in rows] == list(range(1, 300))
summary = {
    'complete': app['complete'], 'runtime_command': read('runtime-command.json'),
    'wrapper_command': read('resources/run.json'), 'native_entries': app['native'],
    'service_queries': app['queries'], 'file_event': app['file_event'],
    'resource': {
        'document_window_seconds': app['resource_duration_seconds'],
        'query_layout_ms': quantile([row['input_to_layout_ms'] for row in queries]),
        'first_counts': {key: queries[0][key] for key in ['files', 'chunks']},
        'last_counts': {key: queries[-1][key] for key in ['files', 'chunks']},
        'final_counts': {key: app[key] for key in ['final_files', 'final_chunks']},
        'scope': 'Small document-only window; mixed entry repeats one exact OCR query. Asynchronous service counters can differ from final database counts. Backlog not drained; no general throughput or long stability conclusion.'},
    'independent_native': {
        'seconds': native['duration_seconds'], 'expected_ids': 299, 'observed_ids': len(rows),
        'contiguous_ids': [row['id'] for row in rows] == list(range(1, 300)),
        'missing_handlers': sum(row.get('missing', True) for row in rows),
        'missing_windowserver': sum(not isinstance(row.get('input_to_windowserver_ms'), (int, float)) for row in rows),
        'handler_ms': quantile([row.get('input_to_handler_ms') for row in rows]),
        'windowserver_ms': quantile([row.get('input_to_windowserver_ms') for row in rows]),
        'producer_delay_ms': quantile([row.get('producer_delay_ms') for row in rows]),
        'metal_presented_samples': sum(isinstance(row.get('input_to_present_ms'), (int, float)) for row in rows),
        'capture_error': native.get('capture_error_code'),
        'scope': 'Producer emits IDs1..ceil(seconds)-1. Own-window compositor observation, separate from query result drawing and physical monitor scanout.'},
    'resources': {
        'samples': len(samples), 'peak_owned_rss_sum_bytes': max(sum(row['rss_bytes'] for row in sample['owned']) for sample in samples),
        'pressure_values': sorted(set(sample['pressure'].strip() for sample in samples)),
        'scope': 'Sampled RSS sums include shared pages. Whole wrapper includes preparation, initial indexing and cleanup; this is not unique RAM or energy.'}}
(out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps({'complete': summary['complete'], 'native_events': len(rows), 'query_samples': len(queries),
    'wrapper_wall_seconds': summary['wrapper_command']['wall_seconds']}))
