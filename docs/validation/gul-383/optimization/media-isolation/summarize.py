#!/usr/bin/env python3
"""Recompute narrow evidence gates; a timeout or one hit never becomes cohort quality."""
import json
from pathlib import Path


def main():
    root = Path(__file__).resolve().parent
    rows = []
    for name in ['screenshot', 'screenshot-cpu-registration', 'screenshot-cpu-registration-final',
                 'screenshot-fixed', 'audio-fixed', 'video-fixed', 'startup-fixed']:
        directory = root / name
        if not (directory / 'command.json').exists():
            continue
        command = json.loads((directory / 'command.json').read_text())
        report = json.loads((directory / 'report.json').read_text()) if (directory / 'report.json').exists() else {}
        trace = [json.loads(line) for line in (directory / 'trace.jsonl').read_text().splitlines()] if (directory / 'trace.jsonl').exists() else []
        responses = [event for event in trace if event['stage'] == 'media-response']
        requests = [event for event in trace if event['stage'] == 'media-request']
        persistence = json.loads((directory / 'process-and-persistence.json').read_text()) if (directory / 'process-and-persistence.json').exists() else []
        chunks = [chunk for snapshot in persistence for chunk in snapshot.get('chunks', [])]
        unique_chunks = {json.dumps(chunk, sort_keys=True): chunk for chunk in chunks}
        persisted = list(unique_chunks.values())
        target = {'screenshot': 'screen.png', 'audio': 'boundary.wav', 'video': 'scene.mov'}.get(command['media'])
        queried = report.get('queries', [])
        queries_hit = bool(queried) and all(any(hit['name'] == target for hit in query['hits']) for query in queried)
        reopened_hit = any(hit['name'] == target for hit in report.get('reopened_query', {}).get('hits', []))
        narrow_pass = (command['exit_code'] == 0 and report.get('ready') is True and bool(responses)
                       and all(response['valid'] and response['dimensions'] == 768 for response in responses)
                       and queries_hit and reopened_hit and not command.get('post_clear_pids_requiring_cleanup'))
        startup_pass = (command.get('mode') == 'startup' and command['exit_code'] == 0
                        and report.get('startup_vector_dimensions') == [768]
                        and report.get('startup_vectors_valid') is True and report.get('cleaned_up') is True)
        rows.append({'attempt': name, 'command': command, 'ready': report.get('ready'),
                     'media_requests': requests, 'media_responses': responses, 'persisted_chunks_observed': persisted,
                     'queries_hit': queries_hit, 'reopened_hit': reopened_hit, 'narrow_path_pass': narrow_pass,
                     'native_startup_pass': startup_pass,
                     'invalid_build_race': (directory / 'build-race.json').exists(),
                     'snapshot_count': len(report.get('snapshots', []))})
    summary = {'attempts': rows, 'cohort_recall_or_no_answer_claim': False,
               'scope': 'Synthetic single-input/path diagnostics. No oracle, ranking, quality denominator, resource budget or permission bypass. CPU-registration experiment is diagnostic only. Native helper fix runs have separate source/binary/continuous coverage fingerprints.',
               'batch_complete': False}
    (root / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps([{key: row[key] for key in ['attempt', 'ready', 'narrow_path_pass', 'invalid_build_race']} for row in rows]))


if __name__ == '__main__':
    main()
