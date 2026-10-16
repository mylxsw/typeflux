#!/usr/bin/env python3
"""Compare touched-file lint against the exact base without altering its baseline."""
from pathlib import Path
from collections import Counter
import json
import subprocess

root = Path.cwd()
evidence = Path(__file__).resolve().parent
paths = subprocess.check_output(['git', 'diff', '--name-only', '2bff08de'], text=True).splitlines()
paths += subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard'], text=True).splitlines()
paths = sorted({p for p in paths if p.endswith('.swift') and p.startswith(('Sources/', 'Tests/'))})
base = root / '.build/lint-base'
base.mkdir(exist_ok=True)
base_paths = []
for path in paths:
    result = subprocess.run(['git', 'show', '2bff08de:' + path], capture_output=True)
    if result.returncode == 0:
        target = base / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(result.stdout)
        base_paths.append(str(target))

def lint(paths):
    result = subprocess.run(['swiftlint', 'lint', '--quiet', '--strict', '--config', str(root / '.swiftlint.yml'),
                             '--reporter', 'json', *paths], capture_output=True, text=True)
    return result.returncode, json.loads(result.stdout)

current_code, current = lint(paths)
base_code, previous = lint(base_paths)
for row in previous:
    row['file'] = str(Path(row['file']).relative_to(base))
for row in current:
    row['file'] = str(Path(row['file']).relative_to(root))
old_count = Counter((x['file'], x['rule_id']) for x in previous)
new_count = Counter((x['file'], x['rule_id']) for x in current)
new = {str(key): count - old_count[key] for key, count in new_count.items() if count > old_count[key]}
report = {'command': 'swiftlint lint --quiet --strict --config .swiftlint.yml --reporter json <changed Swift files>',
          'current_exit': current_code, 'base_exit': base_code, 'base_warnings': len(previous),
          'current_warnings': len(current), 'additional_file_rule_counts': new,
          'current': current, 'base': previous}
(evidence / 'lint-comparison.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({key: value for key, value in report.items() if key not in ('current', 'base')}))
