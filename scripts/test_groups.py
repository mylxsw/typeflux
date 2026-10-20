#!/usr/bin/env python3
"""Run an explicit macOS test scope, with audited parallelism and no full fallback."""

import argparse
from collections import defaultdict
from contextlib import nullcontext
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_runtime as runtime
from test_profiles import PROFILES, selected_profile_files


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
# Reviewed suites use only per-test synthetic data; no windows, shared defaults,
# localization, pasteboard, network or filesystem. New suites default to serial.
PARALLEL_SUITES = {
    "ScrollStitcherTests": "xctest",
    "DirectionalScrollStitcherTests": "xctest",
    "AskCalculatorDetectionTests": "swift-testing",
    "AskCalculatorLexerTests": "swift-testing",
    "AskCalculatorNumberTests": "swift-testing",
}


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
            if line.startswith(("TypefluxTests.", "TypefluxTests/", "TypefluxFocusedTests.", "TypefluxFocusedTests/")):
                raise ValueError(f"Unsupported test identifier: {line}")
            continue
        if line in tests:
            continue
        if match[1] not in {"TypefluxTests", "TypefluxFocusedTests"}:
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
    return rf"^Typeflux(?:Focused)?Tests[./](?:{names})[./]"


def positive_integer(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def select_tests(groups, group=None, suites=(), filters=(), full=False, partial_build=False):
    inventory = {test for entries in groups.values() for tests in entries.values() for test in tests}
    if full:
        return inventory
    selected = set()
    for suite in suites:
        pattern = suite_filter({suite})
        matches = {test for test in inventory if re.search(pattern, test)}
        if not matches:
            raise ValueError(f"No discovered tests in suite: {suite}")
        selected.update(matches)
    for expression in filters:
        try:
            pattern = re.compile(expression)
        except re.error as error:
            raise ValueError(f"Invalid filter {expression!r}: {error}") from error
        matches = {test for test in inventory if pattern.search(test)
                   or pattern.search(test.replace("TypefluxFocusedTests", "TypefluxTests", 1))}
        if not matches:
            raise ValueError(f"Filter matches no discovered tests: {expression}")
        selected.update(matches)
    if group:
        members = {test for tests in groups[group].values() for test in tests}
        selected = selected & members if suites or filters else members
    if not selected:
        raise ValueError("The selected scope contains no tests")
    if selected == inventory and not partial_build:
        raise ValueError("Selection covers the entire inventory; use --full --reason instead")
    return selected


def execution_phases(selected, sources, serial=False):
    phases = defaultdict(set)
    for test in selected:
        suite = TEST_ID.fullmatch(test)[2].split(".")[0]
        mode = "serial" if serial or sources[suite] != "unit" else PARALLEL_SUITES.get(suite, "serial")
        # XCTest IDs omit a signature; Swift Testing IDs include one. If a
        # registered suite migrates frameworks, keep both runners enabled rather
        # than silently omitting tests using stale registry metadata.
        framework = "swift-testing" if test.endswith(")") else "xctest"
        if mode != "serial" and mode != framework:
            mode = "serial"
        phases[mode].add(test)
    return [(mode, phases[mode]) for mode in ("xctest", "swift-testing", "serial") if phases[mode]]


def test_filter(tests, inventory=None):
    complete_suites = set()
    if inventory:
        members = defaultdict(set)
        for test in inventory:
            members[TEST_ID.fullmatch(test)[2].split(".")[0]].add(test)
        complete_suites = {suite for suite, cases in members.items() if cases <= tests}
    # Swift Testing's runtime ID omits the trailing argument signature printed
    # by `swift test list`. Match the method boundary rather than that signature.
    names = {test.split("(", 1)[0] for test in tests
             if TEST_ID.fullmatch(test)[2].split(".")[0] not in complete_suites}
    patterns = ["^(?:" + "|".join(re.escape(name) for name in sorted(names)) + r")(?:\(|$)"] if names else []
    if complete_suites:
        patterns.append(suite_filter(complete_suites))
    return "|".join(patterns)


def phase_command(mode, tests, workers, coverage=False, inventory=None):
    command = ["swift", "test", "--skip-build"]
    if coverage:
        command.extend(["--build-system", "native", "--enable-code-coverage"])
    if mode == "xctest":
        command.extend(["--disable-swift-testing", "--parallel", "--num-workers", str(workers)])
    elif mode == "swift-testing":
        command.extend(["--disable-xctest", "--parallel"])
    else:
        command.append("--no-parallel")
    return [*command, "--filter", test_filter(tests, inventory)]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("group", choices=GROUPS, nargs="?")
    parser.add_argument("--suite", action="append", default=[], help="exact suite name; repeat to select several")
    parser.add_argument("--filter", action="append", default=[], help="discovery-ID regex; repeat to select several")
    parser.add_argument("--full", action="store_true", help="explicit full inventory; requires --reason")
    parser.add_argument("--reason", help="why full validation is necessary")
    parser.add_argument("--from-env", action="store_true", help="read FILTER, SUITE and REASON passed by make")
    parser.add_argument("--list", action="store_true", help="audit discovery and list selected suites without running tests")
    parser.add_argument("--plan", action="store_true", help="build/discover and show selected tests and execution phases only")
    parser.add_argument("--serial", action="store_true", help="disable audited parallelism for timing comparisons")
    parser.add_argument("--workers", type=positive_integer, default=4, help="parallel XCTest workers (default: 4); Swift Testing runs in-process")
    parser.add_argument("--coverage", action="store_true", help="collect coverage for this scope; runs serial to keep one profile")
    parser.add_argument("--skip-build", action="store_true", help="require an unchanged verified native build (manual bypass with --swiftpm)")
    parser.add_argument("--rebuild", action="store_true", help="refresh build/discovery instead of using verified caches")
    parser.add_argument("--swiftpm", action="store_true", help="compatibility path using ordinary SwiftPM and the complete test source set")
    parser.add_argument("--profile", choices=tuple(PROFILES), help="reviewed compact build scope, optionally narrowed by --suite/--filter")
    parser.add_argument("--jobs", type=positive_integer, help="limit Swift build jobs (not test workers)")
    args = parser.parse_args(argv)
    if args.from_env:
        if os.environ.get("FILTER"):
            args.filter.append(os.environ["FILTER"])
        if os.environ.get("SUITE"):
            args.suite.extend(os.environ["SUITE"].split())
        args.reason = args.reason or os.environ.get("REASON")
        args.profile = args.profile or os.environ.get("PROFILE") or None
    if args.profile and args.profile not in PROFILES:
        parser.error("unknown compact build profile")
    if args.full and (not args.reason or not args.reason.strip()):
        parser.error("--full requires a nonempty --reason (announce the reason before running)")
    if args.profile and (args.group or args.full or args.coverage or args.swiftpm):
        parser.error("--profile cannot be combined with resource groups, full/coverage runs or --swiftpm")
    if args.full and (args.group or args.suite or args.filter):
        parser.error("--full cannot be combined with a group, suite or filter")
    if args.profile and not (args.suite or args.filter):
        args.suite.extend(PROFILES[args.profile]["suites"])
    if not (args.group or args.suite or args.filter or args.full or args.list):
        parser.error("choose --suite, --filter or a resource group; no implicit full run")
    started = time.monotonic()
    build_options = ["--jobs", str(args.jobs)] if args.jobs else []
    if args.skip_build:
        build_options.append("--skip-build")
    if args.coverage:
        build_options.extend(["--build-system", "native", "--enable-code-coverage"])
    try:
        environment = runtime.child_environment()
        environment["PWD"] = str(ROOT)
        environment.pop("TYPEFLUX_TEST_FILES", None)
        if args.group == "benchmark":
            environment["TYPEFLUX_SEARCH_BENCH"] = "1"
        native = sys.platform == "darwin" and not (args.swiftpm or args.coverage)
        tools = runtime.native_tools(environment) if native else None
        native = native and tools is not None
        files = (selected_profile_files(args.suite, args.profile)
                 if native and not (args.group or args.full or (args.filter and not args.profile)) else None)
        if files:
            missing = [file for file in files if not (ROOT / "Tests/TypefluxTests" / file).is_file()]
            if missing:
                raise ValueError(f"Missing compact-profile sources: {', '.join(missing)}")
            environment["TYPEFLUX_TEST_FILES"] = json.dumps(files)
            print(f"Compact build: {len(files)} test/fixture files", flush=True)
        with runtime.runner_lock(ROOT) if native else nullcontext(None) as directory:
            return run_scope(args, started, build_options, environment, files, tools, directory)
    except (OSError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as error:
        return error.returncode if error.returncode >= 0 else 128 - error.returncode
    finally:
        print(f"Total wall time: {time.monotonic() - started:.2f}s", flush=True)


def run_scope(args, started, build_options, environment, files, tools, directory):
    if directory:
        discovery, bundle, inputs, artifacts, fingerprints = runtime.prepare(
            ROOT, files, args, environment, directory, tools)
    else:
        discovery_options = build_options
        if args.coverage and not args.skip_build:
            # Swift 6.4 test discovery can build an uninstrumented executable.
            # Build coverage explicitly, then prevent discovery replacing it.
            subprocess.run(["swift", "build", *build_options, "--build-tests"],
                           cwd=ROOT, env=environment, check=True)
            discovery_options = [*build_options, "--skip-build"]
        result = subprocess.run(["swift", "test", *discovery_options, "list"], cwd=ROOT, env=environment,
                                stdout=subprocess.PIPE, text=True, check=True)
        discovery = result.stdout
    sources = source_groups(ROOT / "Tests/TypefluxTests")
    groups = partition_tests(discovery, sources)
    if directory:
        runtime.save_build(directory, discovery, inputs, artifacts, files)
    discovery_seconds = time.monotonic() - started
    for group, suites in groups.items():
        count = sum(len(tests) for tests in suites.values())
        print(f"{group}: {len(suites)} suites, {count} discovered tests", flush=True)
    if args.list and not (args.group or args.suite or args.filter or args.full):
        print("\n".join(sorted(sources.keys() & set().union(*(set(s) for s in groups.values())))))
        return 0
    partial_build = bool(files) and len(files) < len(list((ROOT / "Tests/TypefluxTests").glob("*.swift")))
    selected = select_tests(groups, args.group, args.suite, args.filter, args.full, partial_build)
    if args.list:
        print("\n".join(sorted({TEST_ID.fullmatch(t)[2].split('.')[0] for t in selected})))
        return 0
    phases = execution_phases(selected, sources, args.serial or args.coverage)
    print(f"Discovery/build: {discovery_seconds:.2f}s; selected {len(selected)} test methods", flush=True)
    if args.full:
        print(f"Full validation reason: {args.reason}", flush=True)
    if args.plan:
        for mode, tests in phases:
            print(f"{mode}: {len(tests)} test methods\n" + "\n".join(sorted(tests)))
        return 0
    for mode, tests in phases:
        print(f"Running {mode}: {len(tests)} test methods", flush=True)
        run_started = time.monotonic()
        inventory = {test for suites in groups.values() for cases in suites.values() for test in cases}
        if directory:
            status = runtime.run_native(mode, tests, args.workers, bundle, tools,
                                        runtime.native_environment(bundle, environment, tools),
                                        lambda cases: test_filter(cases, inventory), ROOT, inventory)
        else:
            status = subprocess.run(phase_command(mode, tests, args.workers, args.coverage, inventory),
                                    cwd=ROOT, env=environment).returncode
        print(f"Test execution ({mode}): {time.monotonic() - run_started:.2f}s", flush=True)
        if status:
            print("Fix and retry only the failed method(s) or smallest containing suite; no automatic retry.", file=sys.stderr)
            return status if status >= 0 else 128 - status
    if directory:
        fingerprints.entries = fingerprints.seen.copy()
        if (runtime.build_inputs(ROOT, files, environment, fingerprints) != inputs
                or runtime.artifact_digest(bundle, tools, fingerprints) != artifacts):
            raise ValueError("Inputs or build products changed during testing; results do not validate the current checkout")
        fingerprints.save()
    return 0

if __name__ == "__main__":
    sys.exit(main())
