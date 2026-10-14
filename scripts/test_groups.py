#!/usr/bin/env python3
"""Run a resource-based subset of the macOS tests without changing the package."""

import argparse
from collections import defaultdict
import os
from pathlib import Path
import re
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
GROUPS = ("unit", "integration", "ui", "benchmark")
# Group at file granularity: mixed files and extensions take the strongest isolation.
DECLARATION = re.compile(
    r"^(?:@MainActor\s+)?(?:(?:private|fileprivate|internal|public|final)\s+)*"
    r"(?:struct|class|enum|actor|extension)\s+([A-Za-z_]\w*)", re.MULTILINE,
)
UI_STATE = re.compile(
    r"@MainActor|\.exclusiveUIState\b|\bAppLocalization\b|\bL\s*\("
    r"|\bNSApp\b|\bNSApplication\b|\bNSWindow\b|\bNSPanel\b|\bNSPasteboard\b"
)
INTEGRATION = re.compile(
    r"\bFileManager\b|\bProcess\s*\(|\bURLSession\b|\bSQLite\w*\b"
    r"|\bKeychain\w*\b|\bSecItem\w*\b|\bData\s*\(contentsOf:"
    r"|\bTask\.sleep\b|\bThread\.sleep\b|\busleep\s*\("
)
TEST_ID = re.compile(r"^([A-Za-z_]\w*)[./]([A-Za-z_]\w*(?:\.\w+)*)/.+$")


def source_groups(directory):
    """Map suite names, including extension files, to conservative resource groups."""
    groups = {}
    for path in sorted(directory.glob("*.swift")):
        source = path.read_text(encoding="utf-8")
        if path.name.endswith("BenchmarkTests.swift"):
            group = "benchmark"
        elif UI_STATE.search(source):
            group = "ui"
        elif INTEGRATION.search(source):
            group = "integration"
        else:
            group = "unit"
        for suite in DECLARATION.findall(source):
            previous = groups.get(suite, "unit")
            groups[suite] = max(previous, group, key=GROUPS.index)
    return groups


def partition_tests(output, sources):
    """Audit actual SwiftPM discovery so unknown suites cannot silently disappear."""
    result = {group: defaultdict(list) for group in GROUPS}
    tests = set()
    for line in output.splitlines():
        line = line.strip()
        match = TEST_ID.fullmatch(line)
        if match is None:
            if line.startswith(("TypefluxTests.", "TypefluxTests/")):
                raise ValueError(f"Unsupported test identifier: {line}")
            continue
        if line in tests:
            continue
        if match[1] != "TypefluxTests":
            raise ValueError(f"Unsupported test target: {match[1]}")
        tests.add(line)
        suite = match[2].split(".")[0]
        if suite not in sources:
            raise ValueError(f"No source found for discovered suite: {suite}")
        result[sources[suite]][suite].append(line)
    if not tests:
        raise ValueError("SwiftPM discovered no TypefluxTests tests")
    return result


def suite_filter(suites):
    """Match whole suite names in XCTest and Swift Testing, including nested suites."""
    if not suites:
        raise ValueError("The selected group contains no tests")
    names = "|".join(re.escape(suite) for suite in sorted(suites))
    return rf"^TypefluxTests[./](?:{names})[./]"


def positive_integer(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("group", choices=("all",) + GROUPS, nargs="?", default="all")
    parser.add_argument("--list", action="store_true", help="audit discovery and list selected suites without running tests")
    parser.add_argument("--skip-build", action="store_true", help="reuse an up-to-date local test build")
    parser.add_argument("--jobs", type=positive_integer, help="limit Swift build jobs (not test workers)")
    args = parser.parse_args(argv)
    started = time.monotonic()
    build_options = ["--jobs", str(args.jobs)] if args.jobs else []
    if args.skip_build:
        build_options.append("--skip-build")
    try:
        discovery = subprocess.run(
            ["swift", "test", *build_options, "list"], cwd=ROOT,
            stdout=subprocess.PIPE, text=True, check=True,
        )
        groups = partition_tests(discovery.stdout, source_groups(ROOT / "Tests/TypefluxTests"))
        discovery_seconds = time.monotonic() - started
        for group, suites in groups.items():
            count = sum(len(tests) for tests in suites.values())
            print(f"{group}: {len(suites)} suites, {count} discovered tests", flush=True)
        selected = (set().union(*(set(suites) for suites in groups.values()))
                    if args.group == "all" else set(groups[args.group]))
        pattern = suite_filter(selected)
        if args.list:
            print("\n".join(sorted(selected)))
            return 0
        # AppKit suites share process-wide state. Keep group runs serial;
        # .exclusiveUIState also protects ordinary parallel Swift Testing runs.
        command = ["swift", "test", "--skip-build", "--no-parallel"]
        if args.group != "all":
            command.extend(["--filter", pattern])
        environment = dict(os.environ)
        if args.group == "benchmark":
            environment["TYPEFLUX_SEARCH_BENCH"] = "1"
        print(f"Discovery/build: {discovery_seconds:.2f}s; running {args.group}", flush=True)
        run_started = time.monotonic()
        result = subprocess.run(command, cwd=ROOT, env=environment)
        print(f"Test execution ({args.group}): {time.monotonic() - run_started:.2f}s", flush=True)
        return result.returncode if result.returncode >= 0 else 128 - result.returncode
    except (OSError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as error:
        return error.returncode if error.returncode >= 0 else 128 - error.returncode


if __name__ == "__main__":
    sys.exit(main())
