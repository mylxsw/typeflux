#!/usr/bin/env python3
"""Intersect added production lines with Go coverprofile or LLVM LCOV records.

Run from the repository root. Stage new files first so git diff includes them.
Usage: python3 docs/validation/gul-457/changed_coverage.py COVERAGE... --base origin/main
"""
import argparse
import gzip
import pathlib
import re
import subprocess

def repository_path(source):
    """Use the validated GUL-455 source suffix rule, independent of checkout."""
    parts = pathlib.PurePosixPath(source).parts
    anchors = [i for i in range(len(parts) - 1) if parts[i:i + 2] == ("Sources", "Typeflux")]
    if len(anchors) != 1 or ".." in parts:
        raise ValueError(f"Ambiguous, unrelated or noncanonical source path: {source}")
    return "/".join(parts[anchors[0]:])


def go_repository_path(source):
    prefix = "github.com/mylxsw/typeflux-api/"
    if not source.startswith(prefix) or ".." in pathlib.PurePosixPath(source).parts:
        raise ValueError(f"Unrelated or noncanonical Go source path: {source}")
    return source[len(prefix):]


def read_counts(sources):
    counts = {}
    for source in sources:
        path = pathlib.Path(source)
        coverage = gzip.decompress(path.read_bytes()).decode() if path.suffix == ".gz" else path.read_text()
        if coverage.startswith("mode:"):
            for row in coverage.splitlines()[1:]:
                match = re.match(r"(.+):(\d+)\.\d+,(\d+)\.\d+ \d+ (\d+)$", row)
                if not match:
                    continue
                name, start, end, hits = match.groups()
                # Go profiles contain the module prefix before the repository path.
                name = go_repository_path(name)
                for line in range(int(start), int(end) + 1):
                    key = (name, line)
                    counts[key] = max(counts.get(key, 0), int(hits))
        else:
            name = None
            for row in coverage.splitlines():
                if row.startswith("SF:"):
                    name = repository_path(row[3:])
                elif name and row.startswith("DA:"):
                    line, hits, *_ = row[3:].split(",")
                    key = (name, int(line))
                    counts[key] = max(counts.get(key, 0), int(hits))

    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("coverage", nargs="+")
    parser.add_argument("--base", required=True)
    args = parser.parse_args()
    base = args.base
    counts = read_counts(args.coverage)
    diff = subprocess.check_output(["git", "diff", "--unified=0", base, "--", "*.go", "*.swift"], text=True)
    changed = set()
    name = None
    line = 0
    for row in diff.splitlines():
        if row.startswith("+++ b/"):
            name = row[6:]
        elif row.startswith("@@"):
            line = int(re.search(r"\+(\d+)", row).group(1))
        elif row.startswith("+"):
            if name and not (name.endswith("_test.go") or name.startswith("Tests/")):
                changed.add((name, line))
            line += 1
        elif not row.startswith("-") and not row.startswith("\\"):
            line += 1
    measured = changed & counts.keys()
    if not measured:
        raise SystemExit("No changed production lines measured; check base and coverage input")
    covered = sum(counts[key] > 0 for key in measured)
    for name in sorted({key[0] for key in measured}):
        lines = {key for key in measured if key[0] == name}
        hit = sum(counts[key] > 0 for key in lines)
        print(f"{name}: {hit}/{len(lines)} ({100 * hit / len(lines):.2f}%)")
    print(f"TOTAL: {covered}/{len(measured)} ({100 * covered / len(measured):.2f}%)")
    if covered / len(measured) <= 0.8:
        raise SystemExit("Changed-line coverage must exceed 80%")


if __name__ == "__main__":
    main()
