"""Exercise graceful restart with fake process tools; never touch real apps."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/stop_dev_app.sh"


class StopDevelopmentAppTests(unittest.TestCase):
    def run_stop(self, snapshots, *, refuse=False):
        with tempfile.TemporaryDirectory(prefix="typeflux-stop-") as temporary:
            folder = Path(temporary)
            app = str(folder / "Typeflux Dev [test]+.app")
            executable = app + "/Contents/MacOS/Typeflux"
            processes = [[(pid, executable + suffix) for pid, suffix in snapshot]
                         for snapshot in snapshots]
            fixture = folder / "fixture.json"
            fixture.write_text(json.dumps(processes))
            pgrep = folder / "pgrep"
            pgrep.write_text('''#!/usr/bin/env python3
import json, os, pathlib, re, sys
root = pathlib.Path(os.environ["STOP_TEST_ROOT"])
pattern = sys.argv[-1]
count = root / "count"
index = int(count.read_text()) if count.exists() else 0
snapshots = json.loads((root / "fixture.json").read_text())
# Only complete process-tree polls advance the simulated shutdown.
if " --feature-process" in pattern:
    count.write_text(str(index + 1))
else:
    index = max(0, index - 1)
rows = snapshots[min(index, len(snapshots) - 1)]
matching = [(pid, command) for pid, command in rows if re.search(pattern, command)]
for pid, command in matching:
    print(f"{pid} {command}" if "-fl" in sys.argv else pid)
sys.exit(0 if matching else 1)
''')
            swift = folder / "swift"
            swift.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ["STOP_TEST_ROOT"])
(root / "quit.json").write_text(json.dumps(sys.argv[1:]))
(root / "quit.swift").write_text(sys.stdin.read())
sys.exit(int(os.environ["STOP_TEST_REFUSE"]))
''')
            sleep = folder / "sleep"
            sleep.write_text('#!/bin/sh\nexit 0\n')
            for tool in (pgrep, swift, sleep):
                tool.chmod(0o755)
            environment = dict(os.environ, PATH=f"{folder}:{os.environ['PATH']}",
                               STOP_TEST_ROOT=str(folder), STOP_TEST_REFUSE=str(int(refuse)))
            result = subprocess.run(["bash", str(SCRIPT), app], env=environment,
                                    capture_output=True, text=True, timeout=60)
            quit_file = folder / "quit.json"
            requested = json.loads(quit_file.read_text()) if quit_file.exists() else None
            source_file = folder / "quit.swift"
            source = source_file.read_text() if source_file.exists() else ""
            polls = int((folder / "count").read_text())
            return result, requested, source, polls, executable

    def test_no_running_app_needs_no_quit(self):
        result, requested, _, _, _ = self.run_stop([[]])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(requested)

    def test_selects_host_pids_and_waits_for_children(self):
        child = " --feature-process clipboard --ipc-fd 100"
        result, requested, source, polls, executable = self.run_stop([
            [(20, child), (10, ""), (11, "")], [(20, child)], []])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requested, ["-", executable, "10", "11"])
        self.assertEqual(polls, 3)
        self.assertIn("NSRunningApplication(processIdentifier: pid)", source)
        self.assertIn("app.executableURL?.path == executable", source)
        self.assertNotIn("runningApplications.first", source)

    def test_orphan_child_is_allowed_to_finish_without_quit_request(self):
        result, requested, _, polls, _ = self.run_stop([
            [(20, " --feature-process ring --ipc-fd 100")], []])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(requested)
        self.assertEqual(polls, 2)

    def test_waits_longer_than_old_thirty_second_limit(self):
        snapshots = [[(10, "")]] * 65 + [[]]
        result, _, _, polls, _ = self.run_stop(snapshots)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(polls, 66)

    def test_timeout_reports_remaining_process_without_killing_it(self):
        result, requested, _, polls, executable = self.run_stop([[(10, "")]])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(requested, ["-", executable, "10"])
        self.assertIn("did not quit cleanly", result.stderr)
        self.assertIn("10 " + executable, result.stderr)
        self.assertEqual(polls, 242)  # Initial poll, 240 waits, diagnostic listing.

    def test_refused_quit_stops_before_waiting(self):
        result, _, _, polls, _ = self.run_stop([[(10, "")]], refuse=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(polls, 1)
        self.assertNotIn("Waiting for", result.stdout)

    def test_unrelated_command_arguments_are_not_matched(self):
        result, requested, _, _, _ = self.run_stop([
            [(30, " --some-other-program"), (31, " --feature-process ring --ipc-fd 101")]])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(requested)


if __name__ == "__main__":
    started = time.monotonic()
    try:
        unittest.main()
    finally:
        print(f"Total command wall time: {time.monotonic() - started:.2f}s")
