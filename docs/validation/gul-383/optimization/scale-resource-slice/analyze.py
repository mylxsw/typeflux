"""Keep every native observation and denominator; summarize short samples honestly."""
from collections import defaultdict
import csv
import json
import math
from pathlib import Path
import sys

root = Path.cwd()
out = Path(__file__).resolve().parent
source = out.parent / 'ranking-scale'
files = ['native-gul406-slice2-100000.json', 'contention-gul406-slice2-100000.json']
rows, reports = [], {}
for name in files:
    path = out / name
    if not path.exists():
        path.write_bytes((source / name).read_bytes())
    report = json.loads(path.read_text())
    reports[name] = {key: value for key, value in report.items() if key != 'rows'}
    rows += report['rows']
    partial = source / name.replace('.json', '.partial.json')
    if partial.exists():
        (out / partial.name).write_bytes(partial.read_bytes())

def quantiles(values):
    values = sorted(value for value in values if value is not None)
    return {str(p): values[math.ceil((len(values) - 1) * p)] if values else None
            for p in [.5, .95, .99, 1]}

groups = defaultdict(list)
for row in rows:
    groups[row['entry'], row['scenario']].append(row)
summary = []
for (entry, scenario), observations in sorted(groups.items()):
    summary.append({'entry': entry, 'scenario': scenario, 'n': len(observations), 'expected': 3,
                    'missing': sum(row['outcome'] != 'drawn' for row in observations),
                    **{key: quantiles(row.get(key) for row in observations)
                       for key in ['input_to_publish_ms', 'input_to_draw_ms', 'complete_ms']}})
payload = {'source_commit': '77ef235125864d33e52aa9700e97576d720ae5ad', 'groups': summary,
           'reports': reports, 'scope': 'Three observations per cell. Empirical nearest-rank quantiles; p95/p99 are maxima, not reliable production tail estimates. Native commit through actual result publication/layout/AX; not a compositor fence.'}
(out / 'native-summary.json').write_text(json.dumps(payload, indent=2) + '\n')
with (out / 'native-rows.csv').open('w') as stream:
    keys = ['entry', 'scenario', 'round', 'outcome', 'input_to_publish_ms', 'input_to_draw_ms', 'complete_ms', 'input_uptime', 'overlapping_batch', 'completed_batches']
    writer = csv.DictWriter(stream, fieldnames=keys, extrasaction='ignore', lineterminator='\n')
    writer.writeheader()
    writer.writerows(rows)
print(json.dumps(summary, indent=2))
# The existing resource analyzer uses only the condition's exact time window.
sys.path.insert(0, str(source))
from analyze_final_resource import analyze
analyze(out / 'resource-on')
