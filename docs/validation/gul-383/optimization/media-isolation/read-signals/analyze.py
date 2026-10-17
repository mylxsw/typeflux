"""Correlate exact start identities, successful signals and sampled GGUF reads."""
from collections import defaultdict
import json
import gzip
from pathlib import Path
import signal
import sys


def summarize(rows):
    groups = defaultdict(list)
    for row in rows:
        groups[row['target'] if row['kind'] in (4, 5) else row['pid']].append(row)
    result = {}
    for pid, values in groups.items():
        signals = [r for r in values if r['kind'] == 5]
        identities = {(r['start_seconds'], r['start_microseconds']) for r in signals}
        valid_identity = len(identities) == 1 and all(start > 0 for start, _ in identities)
        stopped, intervals = None, []
        invalid = 0
        for row in sorted(signals, key=lambda r: r['uptime']):
            if not valid_identity or row['result'] != 0:
                invalid += 1; continue
            if row['count'] == signal.SIGSTOP:
                if stopped is not None: invalid += 1
                stopped = row['uptime']
            elif row['count'] == signal.SIGCONT:
                if stopped is None: invalid += 1
                else: intervals.append((stopped, row['entered'])); stopped = None
        reads = [r for r in values if r['kind'] == 3]
        measured = []
        for row in reads:
            begin, end = row['entered'], row['uptime']
            overlap = sum(max(0, min(end, right) - max(begin, left)) for left, right in intervals)
            measured.append({'sequence': row['sequence'], 'bytes': row['result'] * row['size'],
                'cumulative_bytes_before': row['offset'], 'wall_seconds': end - begin,
                'commanded_stop_overlap_seconds': overlap,
                'wall_outside_commanded_stops_seconds': max(0, end - begin - overlap)})
        result[str(pid)] = {'initial_seen': any(r['kind'] == 1 for r in values),
            'signal_calls': len(signals), 'identity_consistent': valid_identity if signals else None,
            'signal_failures_or_unpaired': invalid, 'stop_pairs': len(intervals),
            'unmatched_final_stop': stopped,
            'commanded_stop_seconds': sum(right - left for left, right in intervals),
            'stops_acknowledged_status_4': sum(r['count'] == signal.SIGSTOP and r['status'] == 4 for r in signals),
            'resumes_observed_status_2': sum(r['count'] == signal.SIGCONT and r['status'] == 2 for r in signals),
            'read_completions_recorded': len(reads),
            'last_read_sequence_at_least': max((r['sequence'] for r in reads), default=0),
            'slowest_recorded_reads': sorted(measured, key=lambda r: -r['wall_seconds'])[:8]}
    return result


def main(path):
    path = Path(path)
    raw = path / 'io-events.json'
    data = json.loads(raw.read_text() if raw.exists() else gzip.decompress(Path(str(raw) + '.gz').read_bytes()))
    stages = [json.loads(line) for line in (path / 'native-stages.jsonl').read_text().splitlines()]
    durations = {}
    for stage in stages:
        if stage['stage'].endswith('-end'):
            begin = next((e for e in stages if e['pid'] == stage['pid']
                          and e['stage'] == stage['stage'][:-3] + 'begin'), None)
            if begin: durations[f"{stage['pid']}:{stage['stage'][:-4]}"] = stage['uptime'] - begin['uptime']
    result = {'dropped_events': data['dropped'], 'incomplete_events': data['incomplete'],
              'processes': summarize(data['events']), 'stage_seconds': durations,
              'qos_calls': [r for r in data['events'] if r['kind'] == 6],
              'scope': 'Sparse fread completions and successful signal pairs, not syscall latency or CPU time. '
                       'Cumulative bytes include rereads and are not file offsets. State 4/2 are Darwin stopped/running observations.'}
    (path / 'correlation.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ['processes', 'qos_calls']}, indent=2))


if __name__ == '__main__': main(sys.argv[1])
