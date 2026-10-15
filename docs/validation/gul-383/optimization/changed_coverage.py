#!/usr/bin/env python3
"""Intersect final LLVM executable lines with git additions, including untracked Swift files."""
import argparse
import json
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--lcov", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path.cwd().resolve()
    changes = {}
    path = None
    diff = subprocess.check_output(["git", "diff", "--no-ext-diff", "--unified=0", args.base,
                                    "--", "Sources/Typeflux"], text=True)
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            path = line[6:]
            changes.setdefault(path, set())
        elif path and (match := re.match(r"@@ .*\+(\d+)(?:,(\d+))? @@", line)):
            start, count = int(match[1]), int(match[2] or 1)
            changes[path].update(range(start, start + count))
    for path in subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard"], text=True).splitlines():
        if path.startswith("Sources/Typeflux/") and path.endswith(".swift"):
            changes[path] = set(range(1, len(Path(path).read_text().splitlines()) + 1))
    executable = {}
    path = None
    for line in args.lcov.read_text().splitlines():
        if line.startswith("SF:"):
            try:
                path = str(Path(line[3:]).resolve().relative_to(root))
            except ValueError:
                path = None
        elif path and line.startswith("DA:"):
            number, count, *_ = line[3:].split(",")
            values = executable.setdefault(path, {})
            values[int(number)] = max(values.get(int(number), 0), int(count))
    files = {}
    for path, additions in sorted(changes.items()):
        if not path.endswith(".swift"):
            continue
        values = {line: count for line, count in executable.get(path, {}).items() if line in additions}
        covered = sum(count > 0 for count in values.values())
        files[path] = {"executable": len(values), "covered": covered,
                       "percent": round(covered / len(values) * 100, 2) if values else None,
                       "uncovered": sorted(line for line, count in values.items() if count == 0)}
    total, covered = sum(row["executable"] for row in files.values()), sum(row["covered"] for row in files.values())
    report = {"baseline": args.base,
              "denominator": "Added/modified executable Swift lines in Sources/Typeflux, including new files, intersected with final LLVM LCOV DA records. Tests, helper wrapper and unchanged vendor code excluded; helper reported separately.",
              "executable": total, "covered": covered, "percent": round(covered / total * 100, 2), "files": files}
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"App changed executable lines: {covered}/{total} ({report['percent']}%)")


if __name__ == "__main__":
    main()
