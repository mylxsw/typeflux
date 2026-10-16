#!/usr/bin/env python3
"""Derive numeric resource/response evidence without using lifetime %CPU as a rate."""
import argparse
import json
import math
import re
from collections import defaultdict
from pathlib import Path


def quantiles(values):
    values = sorted(x for x in values if x is not None)
    return {str(p): values[math.ceil((len(values) - 1) * p)] if values else None
            for p in [.5, .95, .99, 1]}


def ps_seconds(text):
    parts = text.split(':')
    return sum(float(x) * 60 ** i for i, x in enumerate(reversed(parts)))


def analyze(folder):
    raw = json.loads((folder / 'resources.json').read_text())['samples']
    phases = json.loads((folder / 'native-resource.json').read_text())
    result = []
    curves = []
    for phase in phases:
        start, duration = phase['started_unix'], phase['duration_seconds']
        samples = [x for x in raw if start <= x['unix'] <= start + duration]
        previous = {}
        previous_external = {}
        totals = defaultdict(lambda: defaultdict(float))
        points = []
        for sample in samples:
            point = dict(seconds=sample['unix'] - start, cpu_core_percent=0,
                         rss_bytes=0, footprint_bytes=0, helper_rss_bytes=0,
                         helper_footprint_bytes=0, external_cpu_core_percent=0,
                         external_process_present=bool(sample['external_compiler_processes']))
            now = {}
            for process in sample['owned']:
                usage = process['rusage']
                name = process['name']
                total = totals[name]
                total['peak_rss_bytes'] = max(total['peak_rss_bytes'], process['rss_bytes'])
                point['rss_bytes'] += process['rss_bytes']
                if name == 'TypefluxSemanticHelper':
                    point['helper_rss_bytes'] += process['rss_bytes']
                if not usage['available']:
                    total['unavailable_rusage_samples'] += 1
                    continue
                total['available_rusage_samples'] += 1
                footprint = usage['physical_footprint_bytes']
                total['peak_footprint_bytes'] = max(total['peak_footprint_bytes'], footprint)
                point['footprint_bytes'] += footprint
                if name == 'TypefluxSemanticHelper':
                    point['helper_footprint_bytes'] += footprint
                key = (process['pid'], usage['process_start_absolute'])
                now[key] = (sample['unix'], usage)
                if key in previous:
                    timestamp, old = previous[key]
                    elapsed = sample['unix'] - timestamp
                    for field in ['cpu_user_ns', 'cpu_system_ns', 'disk_read_bytes',
                                  'disk_written_bytes', 'pageins']:
                        total['observed_' + field] += max(0, usage[field] - old[field])
                    cpu = sum(max(0, usage[k] - old[k]) for k in ['cpu_user_ns', 'cpu_system_ns'])
                    point['cpu_core_percent'] += 100 * cpu / 1e9 / elapsed
            external_now = {}
            for process in sample['external_compiler_processes']:
                key = process['pid']
                value = ps_seconds(process['cpu_time'])
                external_now[key] = value
                if key in previous_external and points:
                    elapsed = point['seconds'] - points[-1]['seconds']
                    point['external_cpu_core_percent'] += 100 * max(0, value - previous_external[key]) / elapsed
            previous, previous_external = now, external_now
            swap = re.search(r'used = ([0-9.]+)M', sample['swap'] or '')
            point['swap_mb'] = float(swap[1]) if swap else None
            compressor = re.search(r'Pages occupied by compressor:\s+(\d+)', sample['vm_stat'] or '')
            page = re.search(r'page size of (\d+)', sample['vm_stat'] or '')
            point['compressor_bytes'] = int(compressor[1]) * int(page[1]) if compressor and page else None
            devices = sample['gpu_statistics'] or []
            point['global_gpu_percent'] = max((g['Device Utilization %'] for g in devices
                                              if 'Device Utilization %' in g), default=None)
            points.append(point)
        inputs = phase['response_probe']['inputs']
        tail = []
        for item in inputs:
            value = item.get('input_to_windowserver_ms')
            if value is None or value < 100:
                continue
            unix = phase['response_probe']['started_unix'] + item['sent_uptime'] - phase['response_probe']['started_uptime']
            nearest = min(zip(samples, points), key=lambda x: abs(x[0]['unix'] - unix))
            tail.append(dict(id=item['id'], kind=item['kind'], windowserver_ms=value,
                             seconds=unix - start, nearest_sample_offset_seconds=nearest[0]['unix'] - unix,
                             external_process_present=nearest[1]['external_process_present'],
                             observed_external_cpu_core_percent=nearest[1]['external_cpu_core_percent']))
        per_kind = {}
        for kind in ['keyboard', 'mouse', 'window']:
            rows = [x for x in inputs if x['kind'] == kind]
            per_kind[kind] = dict(n=len(rows), missing_handler=sum(x.get('input_to_handler_ms') is None for x in rows),
                                  missing_windowserver=sum(x.get('input_to_windowserver_ms') is None for x in rows),
                                  invalid_handler_context=sum(not x.get('window_context_at_handler', {}).get('visible', False)
                                      or not x.get('window_context_at_handler', {}).get('on_active_space', False)
                                      or not x.get('window_context_at_handler', {}).get('key', False)
                                      or x.get('window_context_at_handler', {}).get('occluded', True) for x in rows),
                                  windowserver_ms=quantiles(x.get('input_to_windowserver_ms') for x in rows),
                                  handler_ms=quantiles(x.get('input_to_handler_ms') for x in rows),
                                  producer_delay_ms=quantiles(x.get('producer_delay_ms') for x in rows))
        cpu_seconds = sum(x.get('observed_cpu_user_ns', 0) + x.get('observed_cpu_system_ns', 0)
                          for x in totals.values()) / 1e9
        db = phase['final_database_snapshot']
        result.append(dict(condition=phase['condition'], wall_seconds=duration, samples=len(samples),
                           per_kind=per_kind, per_process=dict(totals), observed_cpu_seconds=cpu_seconds,
                           observed_mean_cpu_core_percent=cpu_seconds / duration * 100,
                           cpu_core_percent=quantiles(x['cpu_core_percent'] for x in points),
                           owned_sum_rss_bytes=quantiles(x['rss_bytes'] for x in points),
                           owned_sum_footprint_bytes=quantiles(x['footprint_bytes'] for x in points),
                           embedding_helpers_sum_rss_bytes=quantiles(x['helper_rss_bytes'] for x in points),
                           embedding_helpers_sum_footprint_bytes=quantiles(x['helper_footprint_bytes'] for x in points),
                           external_process_present_samples=sum(x['external_process_present'] for x in points),
                           external_observed_cpu_core_percent=quantiles(x['external_cpu_core_percent'] for x in points),
                           swap_mb=dict(first=points[0]['swap_mb'], last=points[-1]['swap_mb'],
                                        minimum=min(x['swap_mb'] for x in points), maximum=max(x['swap_mb'] for x in points)),
                           pressure_values=sorted(set(x['pressure'] for x in samples)),
                           thermal_values=sorted(set(x['thermal'] for x in samples)),
                           process_info_thermal_states=sorted(set(x['thermal'] for x in phase['progress'])),
                           global_gpu_percent=quantiles(x['global_gpu_percent'] for x in points),
                           inputs_over_100ms=tail, published=phase['published'], database=db,
                           effective_vectors_per_second=db['published_vectors'] / duration,
                           completed_jobs_per_second=db['jobs_done'] / duration,
                           supplied_files=phase['supplied_files']))
        curves.append(dict(condition=phase['condition'], points=points,
                           latency=[dict(seconds=x['sent_uptime'] - phase['response_probe']['started_uptime'],
                                         ms=x.get('input_to_windowserver_ms'), kind=x['kind']) for x in inputs]))
    payload = dict(scope='Sequential OFF/ON phases; measured durations are reported per condition. Observed CPU and per-process physical IO are lower bounds from adjacent samples of identical PID/start-time; first/last intervals and processes entirely between samples are missed. CPU 100% means one core, not machine capacity. RSS sums shared pages; footprint sums are not exact unique machine RAM. Global IOAccelerator GPU counters include other applications. External compiler/test process presence and adjacent cumulative CPU deltas are separate; nearest-sample overlap is not causal attribution. Own-window ScreenCaptureKit displayTime is a WindowServer observation, not physical HID/monitor scanout or search-result rendering. No privileged watts/energy data. Missing values remain null.', phases=result)
    (folder / 'summary.json').write_text(json.dumps(payload, indent=2) + '\n')
    return curves


def plot(folder, curves):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    figure, axes = plt.subplots(3, 2, figsize=(13, 10), sharex=True, sharey='row')
    for col, curve in enumerate(curves):
        points = curve['points']
        t = [x['seconds'] / 60 for x in points]
        axes[0, col].plot(t, [x['cpu_core_percent'] for x in points], label='Owned CPU (observed)')
        axes[0, col].plot(t, [x['external_cpu_core_percent'] for x in points], alpha=.55, label='External compiler/test CPU')
        axes[0, col].set(ylabel='% of one core', title=curve['condition'])
        axes[0, col].legend(fontsize=8)
        axes[1, col].plot(t, [x['rss_bytes'] / 2**20 for x in points], label='Sum RSS')
        axes[1, col].plot(t, [x['footprint_bytes'] / 2**20 for x in points], label='Sum reported footprint')
        axes[1, col].plot(t, [x['helper_rss_bytes'] / 2**20 for x in points], label='Embedding helper RSS')
        axes[1, col].set(ylabel='MiB (shared pages overlap)')
        axes[1, col].legend(fontsize=8)
        for kind in ['keyboard', 'mouse', 'window']:
            rows = [x for x in curve['latency'] if x['kind'] == kind and x['ms'] is not None]
            axes[2, col].scatter([x['seconds'] / 60 for x in rows], [x['ms'] for x in rows], s=6, label=kind)
        axes[2, col].set(xlabel='Minutes in phase', ylabel='Input → WindowServer (ms)')
        axes[2, col].legend(fontsize=8)
        for ax in axes[:, col]:
            ax.grid(alpha=.2)
    provenance = folder / 'provenance.json'
    source = json.loads(provenance.read_text()).get('source_commit', folder.name) if provenance.is_file() else folder.name
    figure.suptitle(f'Source {source[:12]}: actual mixed-file indexing OFF / ON\nObserved CPU/IO miss short-lived process tails; compositor observation is not physical scanout', fontsize=11)
    figure.tight_layout(rect=(0, 0, 1, .95))
    figure.savefig(folder / 'resource-curves.png', dpi=160)
    figure.savefig(folder / 'resource-curves.svg')
    plt.close(figure)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--folder', type=Path, default=Path(__file__).parent / 'resource-after-final')
    parser.add_argument('--plots', action='store_true')
    args = parser.parse_args()
    curves = analyze(args.folder)
    if args.plots:
        plot(args.folder, curves)
    print(json.dumps(dict(output=str(args.folder / 'summary.json'), phases=len(curves))))
