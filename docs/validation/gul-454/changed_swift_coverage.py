"""Intersect added production lines with unique LCOV executable lines."""
from pathlib import Path
import gzip
import json
import re
import subprocess

BASE = "17f06a87680a968f4c33dc81c3f3973a2ab316f7"
ROOT = Path(__file__).resolve().parents[3]
DIRECTORY = Path(__file__).resolve().parent
coverage = {}
for artifact in sorted(DIRECTORY.glob("swift-*.lcov.gz")):
    name = None
    for row in gzip.decompress(artifact.read_bytes()).decode().splitlines():
        if row.startswith("SF:"):
            name = row[3:].split("/typeflux/")[-1]
            coverage.setdefault(name, {})
        elif row.startswith("DA:") and name:
            line, hits = map(int, row[3:].split(",")[:2])
            coverage[name][line] = max(coverage[name].get(line, 0), hits)

files = subprocess.check_output(["git", "diff", BASE, "--name-only"], cwd=ROOT, text=True).splitlines()
files += [str(path.relative_to(ROOT)) for path in (ROOT / "Sources/Typeflux/Ask/Local").glob("AskBuiltin*.swift")]
report = []
for file in sorted(set(files)):
    if not file.startswith("Sources/") or not file.endswith(".swift"):
        continue
    exists = subprocess.run(["git", "cat-file", "-e", f"{BASE}:{file}"], cwd=ROOT, capture_output=True).returncode == 0
    if exists:
        diff = subprocess.check_output(["git", "diff", BASE, "--unified=0", "--", file], cwd=ROOT, text=True)
        added = set()
        for start, count in re.findall(r"^@@ .*?\+(\d+)(?:,(\d+))? @@", diff, re.M):
            added.update(range(int(start), int(start) + int(count or 1)))
    else:
        added = set(range(1, len((ROOT / file).read_text().splitlines()) + 1))
    executable = {line: hits for line, hits in coverage.get(file, {}).items() if line in added}
    report.append({"file": file, "covered": sum(hits > 0 for hits in executable.values()),
                   "executable": len(executable), "uncovered": sorted(line for line, hits in executable.items() if hits == 0)})
covered = sum(row["covered"] for row in report)
total = sum(row["executable"] for row in report)
print(json.dumps({"base": BASE, "files": report, "covered": covered, "executable": total,
                  "percent": 100 * covered / total if total else None}, indent=2))
