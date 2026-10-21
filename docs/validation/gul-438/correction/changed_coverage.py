#!/usr/bin/env python3
"""Compare portable llvm-cov LCOV executable lines with this issue's Git diff."""
import argparse
import gzip
import hashlib
import json
import re
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--base", default="dfeff6f5305237a23325c6bf8d03fb42c9ddd717")
parser.add_argument("--output", default="changed-coverage.json")
args = parser.parse_args()
ROOT = Path(__file__).resolve().parents[4]
BASE = args.base
directory = Path(__file__).resolve().parent
coverage = {}
for source in sorted(directory.glob("*.lcov*")):
    filename = None
    payload = gzip.decompress(source.read_bytes()).decode() if source.suffix == ".gz" else source.read_text()
    for line in payload.splitlines():
        if line.startswith("SF:"):
            filename = line[3:]
            if filename.startswith(str(ROOT) + "/"):
                filename = filename[len(str(ROOT)) + 1:]
        elif line.startswith("DA:") and filename:
            number, count, *_ = line[3:].split(",")
            counts = coverage.setdefault(filename, {})
            counts[int(number)] = max(counts.get(int(number), 0), int(count))

diff = subprocess.check_output(["git", "diff", "--no-ext-diff", "--unified=0", BASE, "--", "Sources"], cwd=ROOT, text=True)
changed = {}
filename = None
for line in diff.splitlines():
    if line.startswith("+++ b/"):
        filename = line[6:]
    elif line.startswith("@@") and filename:
        start, count = re.search(r"\+(\d+)(?:,(\d+))?", line).groups()
        changed.setdefault(filename, set()).update(range(int(start), int(start) + int(count or 1)))

report = {"base": BASE, "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(), "files": {}}
hit = total = 0
for filename, lines in sorted(changed.items()):
    measured = sorted(lines & coverage.get(filename, {}).keys())
    covered = [number for number in measured if coverage[filename][number] > 0]
    missed = sorted(set(measured) - set(covered))
    digest = hashlib.sha256((ROOT / filename).read_bytes()).hexdigest()
    report["files"][filename] = {"covered": len(covered), "executable": len(measured), "missed_lines": missed, "sha256": digest}
    hit += len(covered)
    total += len(measured)
    print(f"{filename}: {len(covered)}/{len(measured)}; uncovered {missed}")
report.update(covered=hit, executable=total, percent=100 * hit / total if total else 0)
(directory / args.output).write_text(json.dumps(report, indent=2) + "\n")
print(f"TOTAL: {hit}/{total} ({report['percent']:.2f}%)")
if not total or report["percent"] <= 80:
    raise SystemExit("Changed executable-line coverage must exceed 80%")
