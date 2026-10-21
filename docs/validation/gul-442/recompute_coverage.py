#!/usr/bin/env python3
"""Intersect added product Swift lines with LLVM LCOV DA records, using only stdlib."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("lcov", type=Path)
parser.add_argument("--base", default="629013ece134908f15c0800a4ec084af4ff8bbaf")
parser.add_argument("--output", type=Path)
args = parser.parse_args()
root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
diff = subprocess.check_output(["git", "diff", "--no-ext-diff", "--unified=0", args.base, "--", "Sources/Typeflux"], text=True)
added = {}
current = None
line_number = 0
for line in diff.splitlines():
    if line.startswith("+++ b/"):
        current = line[6:]
        if current.endswith(".swift"):
            added[current] = set()
    elif line.startswith("@@"):
        line_number = int(re.search(r"\+(\d+)", line).group(1))
    elif line.startswith("+"):
        if current in added:
            added[current].add(line_number)
        line_number += 1
    elif not line.startswith(("-", "\\")):
        line_number += 1

counters = {}
current = None
for line in args.lcov.read_text().splitlines():
    if line.startswith("SF:"):
        name = line[3:]
        marker = name.find("Sources/Typeflux/")
        current = name[marker:] if marker >= 0 else None
    elif current in added and line.startswith("DA:"):
        number, count, *_ = line[3:].split(",")
        key = (current, int(number))
        counters[key] = max(counters.get(key, 0), int(count))

files = {}
for name, numbers in added.items():
    source = (root / name).read_text().splitlines()
    comment_or_blank = {number for number in numbers
                        if not source[number - 1].strip() or source[number - 1].lstrip().startswith("//")}
    hits = {number: count for (file, number), count in counters.items()
            if file == name and number in numbers and number not in comment_or_blank}
    files[name] = {
        "sha256": hashlib.sha256((root / name).read_bytes()).hexdigest(),
        "added_lines": len(numbers),
        "excluded_comment_or_blank_lines": len(comment_or_blank),
        "instrumented_lines": len(hits),
        "covered_lines": sum(count > 0 for count in hits.values()),
        "uncovered": sorted(number for number, count in hits.items() if not count),
        "line_counts": dict(sorted(hits.items())),
    }
covered = sum(file["covered_lines"] for file in files.values())
instrumented = sum(file["instrumented_lines"] for file in files.values())
report = {"base": args.base, "metric": "unique added/modified product Swift lines with LCOV DA records, excluding blank/comment-only lines",
          "covered": covered, "instrumented": instrumented,
          "percent": round(100 * covered / instrumented, 2) if instrumented else None, "files": files}
result = json.dumps(report, indent=2) + "\n"
if args.output:
    args.output.write_text(result)
print(json.dumps({key: value for key, value in report.items() if key != "files"}))
for name, file in files.items():
    print(name, file["covered_lines"], "/", file["instrumented_lines"], "uncovered:", file["uncovered"])
