#!/usr/bin/env python3
"""Check grandfathered UI literals and prevent the committed baseline from growing."""

import argparse
import collections
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ".swiftlint-ui-baseline.json"


def patterns(root=ROOT):
    """Use exactly the regular expressions SwiftLint reads, without a YAML dependency."""
    config = (root / ".swiftlint.yml").read_text(encoding="utf-8")
    rules = {}
    for name, body in re.findall(r"^  (typeflux_literal_\w+):\n(.*?)(?=^  \w+:|\Z)", config, re.M | re.S):
        expression = re.search(r"^    regex: '(.*)'$", body, re.M)
        if expression:
            rules[name] = re.compile(expression.group(1))
    if len(rules) != 3:
        raise ValueError("Expected all three TypefluxUI literal rules in .swiftlint.yml")
    return rules


def scan(root=ROOT):
    found = collections.Counter()
    rules = patterns(root)
    for path in sorted((root / "Sources").rglob("*.swift")):
        relative = path.relative_to(root).as_posix()
        if relative.startswith("Sources/TypefluxUI/"):
            continue
        source = path.read_text(encoding="utf-8")
        for rule, expression in rules.items():
            for match in expression.finditer(source):
                signature = re.sub(r"\s+", " ", match.group()).strip()
                found[(relative, rule, signature)] += 1
    return found


def decode(entries):
    counts = collections.Counter()
    for entry in entries:
        counts[(entry["file"], entry["rule"], entry["match"])] += entry["count"]
    return counts


def additions(current, previous):
    return current - previous


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-ref", help="Also reject baseline additions relative to this Git revision")
    args = parser.parse_args()
    baseline = decode(json.loads((ROOT / BASELINE).read_text(encoding="utf-8")))
    actual = scan()
    extra = additions(actual, baseline)
    stale = additions(baseline, actual)
    if args.base_ref:
        result = subprocess.run(["git", "show", f"{args.base_ref}:{BASELINE}"], cwd=ROOT,
                                capture_output=True, text=True, check=False)
        if result.returncode == 0:
            extra.update(additions(baseline, decode(json.loads(result.stdout))))
        else:
            # The first PR introduces the ratchet. A bad revision must not silently skip it.
            revision = subprocess.run(["git", "rev-parse", "--verify", args.base_ref], cwd=ROOT,
                                      capture_output=True, text=True, check=False)
            if revision.returncode != 0:
                print("Cannot resolve the comparison revision", file=sys.stderr)
                return 1
            existing = subprocess.run(["git", "cat-file", "-e", f"{args.base_ref}:{BASELINE}"], cwd=ROOT,
                                      capture_output=True, check=False)
            if existing.returncode == 0:
                print("Cannot read the comparison baseline", file=sys.stderr)
                return 1
    if extra:
        for (file, rule, match), count in sorted(extra.items()):
            print(f"{file}: {rule}: {count} new occurrence(s): {match}", file=sys.stderr)
        return 1
    if stale:
        for (file, rule, match), count in sorted(stale.items()):
            print(f"{file}: remove {count} obsolete baseline occurrence(s) for {rule}: {match}", file=sys.stderr)
        return 1
    totals = collections.Counter()
    for (_, rule, _), count in actual.items():
        totals[rule] += count
    print("UI literal baseline holds: " + ", ".join(f"{rule}={totals[rule]}" for rule in patterns()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
