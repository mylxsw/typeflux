"""Synthetic process tables and samplers only; never inspect or launch real apps."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "collect_idle_cpu", Path(__file__).resolve().parents[1] / "collect_idle_cpu.py")
cpu = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cpu)
COMMAND = "/Users/test/Applications/Typeflux Dev.app/Contents/MacOS/Typeflux"


def row(pid=10, seconds="0:10.00", command=COMMAND):
    return f" {pid} 17.7 {seconds} Sat Oct 24 11:20:00 2026 {command}"


class IdleCPUCollectorTests(unittest.TestCase):
    def test_filters_other_programs_and_arguments(self):
        rows = cpu.parse_processes("\n".join([
            row(), row(11, command=COMMAND + " --feature-process chat --ipc-fd 100"),
            row(13, command=COMMAND + " --private-input secret"), "garbage",
            row(14, seconds="invalid"), row(15, command=COMMAND + "Helper")]))
        self.assertEqual([(r["pid"], r["role"]) for r in rows], [(10, "host"), (11, "chat")])

    def test_cpu_time_formats(self):
        for clock, seconds in [("2:03.25", 123.25), ("1:02:03.50", 3723.5),
                               ("2-01:02:03", 176523)]:
            self.assertEqual(cpu.cpu_seconds(clock), seconds)
        with self.assertRaises(ValueError):
            cpu.cpu_seconds("12")

    def test_interval_cpu_and_pid_reuse(self):
        before = cpu.parse_processes(row())
        after = cpu.parse_processes(row(seconds="0:10.80"))
        self.assertEqual(cpu.cpu_deltas(before, after, 4)[0]["intervalCPUPercent"], 20)
        after[0]["started"] = "different start"
        self.assertIsNone(cpu.cpu_deltas(before, after, 4)[0]["intervalCPUPercent"])
        self.assertIsNone(cpu.cpu_deltas(before, before, 0)[0]["intervalCPUPercent"])

    def test_reads_bounded_process_table(self):
        calls = []
        def run(args, **kwargs):
            calls.append((args, kwargs))
            output = (row() + "\n" + row(12, command="/usr/bin/grep " + COMMAND)
                      if "-axo" in args else f"10 {COMMAND}\n12 /usr/bin/grep")
            return subprocess.CompletedProcess(args, 0, stdout=output)
        result = cpu.read_processes(run)
        self.assertEqual([(r["pid"], r["role"]) for r in result], [(10, "host")])
        self.assertEqual(calls[0][0][0], "/bin/ps")
        self.assertEqual(calls[0][1]["timeout"], 5)
        self.assertEqual(len(calls), 2)
        self.assertEqual(cpu.read_processes(
            lambda *args, **kwargs: subprocess.CompletedProcess([], 0, stdout="")), [])

    def test_success_failure_timeout_and_exit(self):
        rows = cpu.parse_processes("\n".join(row(pid) for pid in range(10, 14)))
        reads = iter([rows, rows, rows, rows, rows, []])
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            if args[1] == "12":
                raise subprocess.TimeoutExpired(args, 13)
            if args[1] == "10":
                Path(args[-1]).write_text("synthetic stack")
            return subprocess.CompletedProcess(args, 0 if args[1] == "10" else 1)
        with tempfile.TemporaryDirectory() as directory:
            report = cpu.collect(Path(directory), read=lambda: next(reads), run=run,
                                 sleep=lambda _: None, monotonic=iter([0, 4]).__next__)
            self.assertEqual([s["status"] for s in report["samples"]],
                             ["ok", "failed", "timeout-or-unavailable", "exited-or-replaced"])
            self.assertTrue((Path(directory) / "processes.json").exists())
            self.assertEqual((Path(directory) / "host-10.txt").stat().st_mode & 0o777, 0o600)
        self.assertEqual(len(calls), 3)
        self.assertTrue(all(c[0] == "/usr/bin/sample" for c in calls))

    def test_no_application_is_never_started(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "never starts"):
                cpu.collect(Path(directory), read=lambda: [])

    def test_limits_sample_count_and_file_size(self):
        rows = cpu.parse_processes("\n".join(row(pid) for pid in range(10, 22)))
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            with Path(args[-1]).open("wb") as stack:
                stack.truncate(9 * 1024 * 1024)
            return subprocess.CompletedProcess(args, 0)
        with tempfile.TemporaryDirectory() as directory:
            report = cpu.collect(Path(directory), read=lambda: rows, run=run,
                                 sleep=lambda _: None, monotonic=iter([0, 4]).__next__)
            self.assertEqual(len(calls), 10)
            self.assertEqual(len(report["after"]), 12)
            self.assertTrue(all(s["truncated"] for s in report["samples"]))
            self.assertEqual((Path(directory) / "host-10.txt").stat().st_size, 8 * 1024 * 1024)

    def test_main_reports_collection_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(cpu.tempfile, "mkdtemp", return_value=directory), \
                    patch.object(cpu, "collect", side_effect=RuntimeError("not running")), \
                    patch("sys.argv", ["collect_idle_cpu.py"]):
                with self.assertRaises(SystemExit) as error:
                    cpu.main()
                self.assertEqual(error.exception.code, 1)

    def test_main_archives_private_collection(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory) / "collection"
            folder.mkdir()
            def collect(target):
                (target / "processes.json").write_text("{}")
            with patch.object(cpu.tempfile, "mkdtemp", return_value=str(folder)), \
                    patch.object(cpu, "collect", side_effect=collect), \
                    patch.object(cpu.tempfile, "tempdir", directory), \
                    patch("sys.argv", ["collect_idle_cpu.py"]):
                cpu.main()
            archives = list(Path(directory).glob("*.tar.gz"))
            self.assertEqual(len(archives), 1)
            self.assertEqual(archives[0].stat().st_mode & 0o777, 0o600)
            with cpu.tarfile.open(archives[0]) as archive:
                self.assertIn("collection/processes.json", archive.getnames())


if __name__ == "__main__":
    unittest.main()
