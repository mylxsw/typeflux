#!/usr/bin/env python3
"""Recompute per-PID progress from retained observations, without rerunning old work."""
from collections import Counter, defaultdict
import gzip
import json
from pathlib import Path


def cpu_seconds(text):
    parts = text.split(':')
    return sum(float(value) * 60 ** index for index, value in enumerate(reversed(parts)))


def summarize(rows):
    grouped = defaultdict(list)
    for snapshot in rows:
        for row in snapshot['processes']:
            grouped[row[0]].append((snapshot['seconds'], row))
    result = {}
    for pid, points in grouped.items():
        valid = [(seconds, row) for seconds, row in points
                 if not row[3].startswith(('Z', '?')) and row[7] != '<defunct>']
        if not valid:
            continue
        first, last = valid[0], valid[-1]
        result[pid] = {
            'first_seen_seconds': first[0], 'last_seen_seconds': last[0],
            'observed_wall_seconds': last[0] - first[0],
            'first_cpu_seconds': cpu_seconds(first[1][6]),
            # Exit records may reset TIME/RSS to zero. Preserve the actual live maximum.
            'maximum_cpu_seconds': max(cpu_seconds(row[6]) for _, row in valid),
            'cpu_progress_seconds': max(cpu_seconds(row[6]) for _, row in valid) - cpu_seconds(first[1][6]),
            'maximum_rss_kib': max(int(row[5]) for _, row in valid),
            'sampled_states': dict(Counter(row[3] for _, row in valid)),
            'comm': first[1][7],
            'state_transitions': [{'seconds': seconds, 'state': row[3], 'cpu': row[6]}
                for index, (seconds, row) in enumerate(valid)
                if index == 0 or row[3] != valid[index - 1][1][3]],
        }
    return result


def main():
    out = Path(__file__).resolve().parent
    base = out.parent
    result = {'limitations': [
        'Original process sampling is roughly once per second. T sample counts are not paused durations.',
        'Original traces do not record budget counters or each SIGSTOP/SIGCONT. Exact effective wall time is unavailable.',
        'Trace seconds start inside the probe; process seconds start in the runner, before probe startup. No exact clock alignment is inferred.',
        'CPU TIME is cumulative scheduled CPU (0.01 s resolution), not allowed-running wall time or proof of a hardware cause.',
        'One-second stack samples only identify the sampled stage, not every stage occupied during the attempt.',
    ], 'attempts': {}}
    for label in ['screenshot-fixed', 'audio-fixed', 'video-fixed', 'startup-fixed']:
        directory = base / label
        command = json.loads((directory / 'command.json').read_text())
        report = json.loads((directory / 'report.json').read_text())
        trace = [json.loads(line) for line in (directory / 'trace.jsonl').read_text().splitlines()]
        states, previous = [], None
        for snapshot in report.get('snapshots', []):
            current = {key: snapshot.get(key) for key in ['phase', 'waiting', 'pressure']}
            if current != previous:
                states.append(dict(current, seconds=snapshot['seconds']))
                previous = current
        stacks = {}
        for sample in directory.glob('*sample*.txt.gz'):
            lines = gzip.open(sample, 'rt').read().splitlines()
            stacks[sample.name] = [line.strip() for line in lines if any(token in line for token in [
                'Process:', 'Parent Process:', 'Launch Time:', 'Date/Time:',
                'Encoder.embedMedia', 'ggml_graph_compute', 'clip_image_batch_encode',
                'llama_backend_init', 'ggml_backend_metal_reg', 'dyld4::prepare',
                '_GLOBAL__sub_I_clip.cpp'])]
        result['attempts'][label] = {
            'command_wall_seconds': command['wall_seconds'], 'exit_code': command['exit_code'],
            'complete': report.get('complete', False), 'per_pid': summarize(
                json.loads((directory / 'process-and-persistence.json').read_text())),
            'trace': trace, 'service_state_transitions': states, 'sampled_stages': stacks,
        }
    (out / 'history-analysis.json').write_text(json.dumps(result, indent=2) + '\n')
    for label, attempt in result['attempts'].items():
        print(label, [(pid, round(row['observed_wall_seconds'], 3), row['cpu_progress_seconds'], row['sampled_states'])
            for pid, row in attempt['per_pid'].items() if 'SemanticHelper' in row['comm']])


if __name__ == '__main__':
    main()
