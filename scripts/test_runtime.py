"""Verified macOS test artifacts and batched native execution, without result caching."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

VERSION = 1
PRIVATE_ENV = re.compile(r"^(MULTICA_|CODEX_)|TOKEN|SECRET|PASSW(?:OR)?D|API_KEY|PRIVATE_KEY|ACCESS_KEY"
                         r"|CREDENTIAL|AUTHORIZATION|COOKIE|BEARER", re.IGNORECASE)
IGNORED_DIRS = {".git", ".build", ".swiftpm", "__pycache__"}


def child_environment():
    # XCTest can dump its environment on launch errors. Runtime credentials are
    # unrelated to building/testing the app and must never reach that diagnostic.
    return {key: value for key, value in os.environ.items() if not PRIVATE_ENV.search(key)}


def developer_directory(environment):
    if environment.get("DEVELOPER_DIR"):
        return Path(environment["DEVELOPER_DIR"])
    result = subprocess.run(["xcode-select", "--print-path"], env=environment,
                            stdout=subprocess.PIPE, text=True, check=True)
    return Path(result.stdout.strip())


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def read_json(path):
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as file:
        temporary = Path(file.name)
        try:
            json.dump(value, file, sort_keys=True)
            file.flush()
            os.fsync(file.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


@contextmanager
def runner_lock(root):
    directory = root / ".build/test-runner"
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield directory
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


class Fingerprints:
    def __init__(self, path):
        self.path = path
        self.entries = read_json(path)
        self.seen = {}

    def file(self, path):
        info = path.stat()
        signature = [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]
        previous = self.entries.get(str(path), {})
        if isinstance(previous, dict) and previous.get("stat") == signature:
            value = previous.get("hash")
        else:
            value = None
        if not isinstance(value, str) or len(value) != 64:
            with path.open("rb") as file:
                value = hashlib.file_digest(file, "sha256").hexdigest()
        self.seen[str(path)] = {"stat": signature, "hash": value}
        return value

    def tree(self, paths):
        files = set()
        for path in paths:
            if path.is_file():
                files.add(path)
            elif path.is_dir():
                for directory, children, names in os.walk(path):
                    children[:] = sorted(name for name in children if name not in IGNORED_DIRS)
                    files.update(Path(directory) / name for name in names if name != ".DS_Store")
        return digest([(str(file), self.file(file)) for file in sorted(files)])

    def save(self):
        write_json(self.path, self.seen)


def build_inputs(root, files, environment, fingerprints):
    tests = [root / "Tests/TypefluxTests" / file for file in files] if files else [root / "Tests"]
    paths = [root / "Sources", root / "Packages", root / "Package.swift", root / "Package.resolved",
             root / ".swift-version", root / ".build/checkouts", root / ".build/artifacts",
             root / ".build/workspace-state.json", *tests]
    swift = shutil.which("swift", path=environment.get("PATH"))
    developer = str(developer_directory(environment))
    paths.extend([Path(swift)] if swift else [])
    paths.extend([Path(developer) / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend"])
    if environment.get("SDKROOT"):
        paths.append(Path(environment["SDKROOT"]) / "SDKSettings.json")
    # Store only the environment digest, never its values. Selection is not a
    # compiler input; the manifest's explicit file list is included separately.
    build_environment = {key: value for key, value in environment.items()
                         if key not in {"FILTER", "SUITE", "REASON", "PROFILE", "PWD", "OLDPWD", "_", "SHLVL",
                                        "MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES"}}
    return digest([VERSION, files, developer, fingerprints.tree(paths), digest(build_environment)])


def native_tools(environment):
    developer = developer_directory(environment)
    tools = {
        "xctest": developer / "usr/bin/xctest",
        "swift-testing": developer / "Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper",
        "xctest-discovery": developer / "Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-xctest-helper",
    }
    return tools if all(path.is_file() and os.access(path, os.X_OK) for path in tools.values()) else None


def find_bundle(root, files=None):
    name = "TypefluxFocusedTests" if files else "TypefluxTests"
    candidates = [path for path in ((root / ".build/debug" / f"{name}.xctest"),
                                    (root / ".build/debug/TypefluxPackageTests.xctest")) if path.is_dir()]
    if not candidates:
        raise ValueError("Expected a macOS test bundle; use --swiftpm for other build layouts")
    bundle = candidates[0].resolve()
    if not bundle.is_relative_to((root / ".build").resolve()):
        raise ValueError("Test bundle is outside this checkout's build directory")
    if not (bundle / "Contents/MacOS" / bundle.stem).is_file():
        raise ValueError("Test bundle executable is missing")
    return bundle


def artifact_digest(bundle, tools, fingerprints):
    # Keep the complete and compact test bundles independent. Shared runtime
    # resources/frameworks still invalidate both when rebuilt or changed.
    dependencies = [path for path in bundle.parent.iterdir()
                    if path.suffix in {".bundle", ".dylib", ".framework"} or path.name == "PackageFrameworks"]
    return fingerprints.tree([bundle, *dependencies, *tools.values()])


def prepare(root, files, args, environment, directory, tools):
    fingerprints = Fingerprints(directory / "files.json")
    inputs = build_inputs(root, files, environment, fingerprints)
    record_path = directory / ("build-focused.json" if files else "build.json")
    record = read_json(record_path)
    cached = False
    try:
        bundle = find_bundle(root, files)
        artifacts = artifact_digest(bundle, tools, fingerprints)
        cached = (not args.rebuild and record.get("inputs") == inputs and record.get("artifacts") == artifacts
                  and isinstance(record.get("discovery"), str))
    except (OSError, ValueError):
        bundle = None
    if cached:
        discovery = record["discovery"]
        print("Verified build/discovery cache hit; tests will execute again", flush=True)
    else:
        if args.skip_build:
            raise ValueError("No matching verified build; remove --skip-build to rebuild this scope")
        options = ["--jobs", str(args.jobs)] if args.jobs else []
        source_paths = [root / "Sources", root / "Package.swift", root / "Packages",
                        *([root / "Tests/TypefluxTests" / file for file in files] if files else [root / "Tests"])]
        before = fingerprints.tree(source_paths)
        subprocess.run(["swift", "build", *options, "--build-tests"], cwd=root, env=environment, check=True)
        # A successful compiler exit must not bless source edits made mid-build.
        fingerprints.entries = fingerprints.seen.copy()
        if fingerprints.tree(source_paths) != before:
            raise ValueError("Sources changed during the build; retry the same focused scope after edits finish")
        bundle = find_bundle(root, files)
        discovery = discover(bundle, tools, native_environment(bundle, environment, tools), root, directory)
        inputs = build_inputs(root, files, environment, fingerprints)
        artifacts = artifact_digest(bundle, tools, fingerprints)
    fingerprints.save()
    return discovery, bundle, inputs, artifacts, fingerprints


def save_build(directory, discovery, inputs, artifacts, files=None):
    # Called only after the existing discovery audit/selection succeeds.
    path = directory / ("build-focused.json" if files else "build.json")
    write_json(path, {"inputs": inputs, "artifacts": artifacts, "discovery": discovery})


def native_environment(bundle, environment, tools):
    result = dict(environment)
    products = str(bundle.parent)
    developer = tools["xctest"].parents[2]
    frameworks = str(developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks")
    libraries = str(developer / "Platforms/MacOSX.platform/Developer/usr/lib")
    for key, paths in (("DYLD_LIBRARY_PATH", [products, libraries]), ("DYLD_FRAMEWORK_PATH", [products, frameworks])):
        result[key] = os.pathsep.join([*paths, *([result[key]] if result.get(key) else [])])
    return result


def buckets(tests, workers):
    ordered = sorted(tests)
    count = min(workers, len(ordered))
    return [ordered[index::count] for index in range(count)]


def xctest_identifiers(data):
    identifiers = []
    def visit(node, parent=None):
        if not isinstance(node, dict) or not isinstance(node.get("name"), str):
            raise ValueError("Invalid XCTest discovery node")
        if "tests" in node:
            if not isinstance(node["tests"], list):
                raise ValueError("Invalid XCTest discovery children")
            for child in node["tests"]:
                visit(child, node["name"])
        else:
            if not parent or not parent.startswith(("TypefluxTests.", "TypefluxFocusedTests.")):
                raise ValueError("Unsupported XCTest discovery class")
            identifiers.append(f"{parent}/{node['name']}")
    visit(data)
    return identifiers


def discover(bundle, tools, environment, cwd, directory):
    with tempfile.TemporaryDirectory(dir=directory) as temporary:
        output = Path(temporary) / "xctest.json"
        xctest_env = dict(environment, SWIFT_TESTING_ENABLED="0")
        subprocess.run([str(tools["xctest-discovery"]), str(bundle), str(output)], cwd=cwd,
                       env=xctest_env, check=True)
        identifiers = xctest_identifiers(json.loads(output.read_text()))
        binary = bundle / "Contents/MacOS" / bundle.stem
        result = subprocess.run([str(tools["swift-testing"]), "--test-bundle-path", str(binary), str(binary),
                                "--testing-library", "swift-testing", "--list-tests"], cwd=cwd,
                                env=environment, stdout=subprocess.PIPE, text=True)
        # Swift Testing uses EX_UNAVAILABLE (69) for an empty library. XCTest-only
        # closures are valid; the combined inventory audit still rejects no tests.
        if result.returncode and not (result.returncode == 69 and not result.stdout.strip()):
            raise subprocess.CalledProcessError(result.returncode, result.args)
        return "\n".join([*identifiers, result.stdout])


def native_swift_testing_host(root, environment):
    directory = root / ".build/test-runner"
    directory.mkdir(parents=True, exist_ok=True)
    source = Path(__file__).with_name("native_swift_testing.swift")
    developer = developer_directory(environment)
    compiler = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    frameworks = developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks"
    sdk = Path(environment.get("SDKROOT") or developer / "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")
    fingerprints = Fingerprints(directory / "native-host-files.json")
    inputs = fingerprints.tree([source, compiler, frameworks / "Testing.framework", sdk / "SDKSettings.json"])
    host = directory / "native-swift-testing"
    record_path = directory / "native-host.json"
    record = read_json(record_path)
    if (record.get("inputs") != inputs or not host.is_file()
            or record.get("artifact") != fingerprints.file(host)):
        subprocess.run([str(compiler), "-parse-as-library", "-sdk", str(sdk), "-F", str(frameworks),
                        "-framework", "Testing", "-framework", "AppKit", str(source), "-o", str(host)],
                       cwd=root, env=environment, check=True)
        write_json(record_path, {"inputs": inputs, "artifact": fingerprints.file(host)})
    fingerprints.save()
    return host


def run_native(mode, tests, workers, bundle, tools, environment, pattern, cwd, inventory=None):
    xctests = {test for test in tests if not test.endswith(")")}
    swift_tests = tests - xctests
    jobs = buckets(xctests, workers if mode == "xctest" else 1) if xctests else []
    status = 0

    def worker(cases):
        selectors = list(cases)
        if inventory:
            by_class = {}
            for case in inventory:
                if not case.endswith(")"):
                    by_class.setdefault(case.split("/", 1)[0], set()).add(case)
            complete = {name for name, members in by_class.items() if members <= set(cases)}
            selectors = sorted(complete) + [case for case in cases if case.split("/", 1)[0] not in complete]
        command = [str(tools["xctest"]), "-XCTest", ",".join(selectors), str(bundle)]
        xctest_env = dict(environment, SWIFT_TESTING_ENABLED="0")
        result = subprocess.run(command, cwd=cwd, env=xctest_env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        # XCTest treats an unmatched selector as success. Verify the actual count
        # so direct execution cannot turn stale/malformed IDs into false green.
        counts = re.findall(r"Executed (\d+) tests?[,]", result.stdout)
        code = result.returncode
        if not code and (not counts or int(counts[-1]) != len(cases)):
            code = 1
            result.stdout += "\nError: XCTest executed a different number of methods than selected\n"
        return code, result.stdout

    if jobs:
        print(f"Native XCTest: {len(xctests)} methods in {len(jobs)} worker process(es)", flush=True)
        with ThreadPoolExecutor(max_workers=len(jobs)) as executor:
            for code, output in executor.map(worker, jobs):
                print(output, end="", flush=True)
                status = status or code
    if status or not swift_tests:
        return status
    binary = bundle / "Contents/MacOS" / bundle.stem
    if not binary.is_file():
        raise ValueError("Unsupported macOS test executable layout; use --swiftpm")
    if mode == "swift-testing":
        # Reviewed pure suites retain their SwiftPM host and need no AppKit loop.
        command = [str(tools["swift-testing"]), "--test-bundle-path", str(binary), str(binary),
                   "--testing-library", "swift-testing", "--parallel", "--filter", pattern(swift_tests)]
        swift_environment = environment
    else:
        host = native_swift_testing_host(cwd, environment)
        command = [str(host), "--testing-library", "swift-testing", "--no-parallel",
                   "--filter", pattern(swift_tests)]
        swift_environment = dict(environment, TYPEFLUX_TEST_BUNDLE=str(binary))
    # Keep long native runs observable even while a test is awaiting a callback.
    # The runner lock gives this per-checkout file one writer at a time.
    log_path = cwd / ".build/test-runner/swift-testing.log"
    print(f"Native Swift Testing live output: {log_path.relative_to(cwd)}", flush=True)
    with log_path.open("w+") as output:
        result = subprocess.run(command, cwd=cwd, env=swift_environment, stdout=output,
                                stderr=subprocess.STDOUT, text=True)
        output.seek(0)
        log = output.read()
    print(log, end="", flush=True)
    if result.returncode:
        return result.returncode
    # AppKit can terminate its host with exit 0 before Swift Testing finishes.
    # Require the framework's final summary, just as XCTest verifies its count.
    summaries = re.findall(r"Test run with (\d+) tests?(?: in \d+ suites?)? (passed|failed)\b", log)
    if not summaries or summaries[-1] != (str(len(swift_tests)), "passed"):
        print(f"Error: Swift Testing did not confirm completion of all {len(swift_tests)} selected methods",
              flush=True)
        return 1
    return 0
