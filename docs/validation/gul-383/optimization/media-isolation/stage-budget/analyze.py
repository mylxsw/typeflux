#!/usr/bin/env python3
"""Recompute content-free stages and actual-budget counters from the retained one-shot run."""
import argparse
import json
from pathlib import Path


def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def cpu_seconds(value):
    parts = value.split(':')
    return sum(float(x) * 60 ** i for i, x in enumerate(reversed(parts)))


def analyze(root):
    trace = rows(root / 'trace.jsonl')
    native = rows(root / 'native-stages.jsonl')
    snapshots = json.loads((root / 'process-and-persistence.json').read_text())
    report = json.loads((root / 'report.json').read_text())
    origin = trace[0]['uptime'] - trace[0]['seconds']
    processes = {}
    for sample in snapshots:
        for row in sample['processes']:
            pid = row[0]
            item = processes.setdefault(pid, {'executable': row[7], 'samples': [], 'stages': []})
            item['samples'].append({'seconds': sample['seconds'], 'state': row[3],
                                    'cpu_seconds': cpu_seconds(row[6]), 'rss_kib': int(row[5])})
    for event in native:
        item = processes.setdefault(str(event['pid']), {'samples': [], 'stages': []})
        item['stages'].append({'stage': event['stage'], 'probe_seconds': event['uptime'] - origin})
    for item in processes.values():
        live = [x for x in item['samples'] if not x['state'].startswith('Z')]
        if live:
            # Exit snapshots may reset CPU to zero; use only non-zombie samples.
            item['observed_cpu_progress_seconds'] = max(x['cpu_seconds'] for x in live) - live[0]['cpu_seconds']
            item['live_observation_wall_seconds'] = live[-1]['seconds'] - live[0]['seconds']
            item['state_counts'] = {state: sum(x['state'] == state for x in live) for state in sorted({x['state'] for x in live})}
        item['native_entry_observed'] = any(x['stage'] == 'swift-entry' for x in item['stages'])
    before = [e for e in trace if e['stage'] == 'media-request-budget-before']
    after = [e for e in trace if e['stage'] == 'media-request-budget-after']
    requests = []
    for start, end in zip(before, after):
        row = {'start_seconds': start['seconds'], 'end_seconds': end['seconds'],
               'actual_budget_present': start.get('budget_present') is True and end.get('budget_present') is True}
        if row['actual_budget_present']:
            assert start['budget_id'] == end['budget_id']
            wall = end['seconds'] - start['seconds']
            delta = end['yield_milliseconds'] - start['yield_milliseconds']
            count = end['yields'] - start['yields']
            row.update(budget_id=start['budget_id'], enabled=start['enabled'], wall_seconds=wall,
                       accounted_budget_yield_seconds=delta / 1000,
                       accounted_yields=count, counter_rounding_bound_seconds=count * .0005,
                       wall_outside_accounted_yields_seconds=wall - delta / 1000,
                       interruptions=end['interruptions'] - start['interruptions'])
        requests.append(row)
    return {'processes': processes, 'requests': requests,
            'budget_snapshots': sum(e['stage'] == 'actual-budget-snapshot' for e in trace),
            'media_requests': sum(e['stage'] == 'media-request' for e in trace),
            'media_responses': sum(e['stage'] == 'media-response' for e in trace),
            'release_events': [e for e in trace if 'release' in e['stage'] or 'retired' in e['stage']],
            'waiting_snapshots': [{'seconds': s['seconds'], 'waiting': s['waiting'], 'pressure': s['pressure']}
                                  for s in report.get('snapshots', []) if s['waiting'] is not None],
            'complete': report['complete'],
            'limits': ['Counters are from the actual media TaskLocal budget, shared across its work scope.',
                       'No per-PID signal-pair timestamps; T samples do not measure exact suspension.',
                       'Wall outside accounted yields includes I/O, scheduler delays and any uncounted in-flight yield; it is not native compute time.',
                       'Native phases come from a diagnostic source copy; no product media acceptance is inferred.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    args = parser.parse_args()
    result = analyze(args.run)
    (args.run / 'analysis.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result[key] for key in ['requests', 'budget_snapshots', 'media_requests', 'media_responses', 'complete']}, indent=2))


if __name__ == '__main__':
    main()
