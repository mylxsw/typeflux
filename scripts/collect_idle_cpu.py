#!/usr/bin/env python3
"""Collect CPU deltas and bounded stacks from already-running Typeflux apps."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import time


EXECUTABLE = re.compile(
    r"^(?P<path>/[^\n]*\.app/Contents/MacOS/Typeflux)"
    r"(?: --feature-process (?P<role>[a-z]+) --ipc-fd [0-9]+)?$")
MAX_PROCESSES = 10


def cpu_seconds(value):
    """macOS TIME is [[days-]hours:]minutes:seconds.hundredths."""
    days, separator, clock = value.partition("-")
    if not separator:
        days, clock = "0", value
    fields = clock.split(":")
    if not 2 <= len(fields) <= 3:
        raise ValueError("Invalid CPU time")
    return int(days) * 86400 + sum(float(part) * 60 ** index
                                  for index, part in enumerate(reversed(fields)))


def parse_processes(output):
    rows = []
    for line in output.splitlines():
        fields = line.split(None, 8)
        if len(fields) != 9:
            continue
        match = EXECUTABLE.fullmatch(fields[8])
        if not match:
            continue
        try:
            rows.append(dict(pid=int(fields[0]), reportedCPUPercent=float(fields[1]),
                             cpuSeconds=cpu_seconds(fields[2]), started=" ".join(fields[3:8]),
                             executable=match["path"], role=match["role"] or "host"))
        except ValueError:
            continue
    return rows


def read_processes(run=subprocess.run):
    result = run(["/bin/ps", "-ww", "-axo", "pid=,pcpu=,time=,lstart=,command="],
                 capture_output=True, text=True, check=True, timeout=5)
    candidates = parse_processes(result.stdout)
    if not candidates:
        return []
    # Command text alone can match a grep/editor argument. Verify the actual
    # executable reported by ps separately, preserving spaces in bundle paths.
    result = run(["/bin/ps", "-ww", "-p", ",".join(str(row["pid"]) for row in candidates),
                  "-o", "pid=,comm="], capture_output=True, text=True, timeout=5)
    if result.returncode not in (0, 1):
        result.check_returncode()
    executables = {}
    for line in result.stdout.splitlines():
        pair = line.split(None, 1)
        if len(pair) == 2 and pair[0].isdigit():
            executables[int(pair[0])] = pair[1]
    return [row for row in candidates if executables.get(row["pid"]) == row["executable"]]


def identity(row):
    return row["pid"], row["started"], row["executable"], row["role"]


def cpu_deltas(before, after, elapsed):
    previous = {identity(row): row for row in before}
    result = []
    for row in after:
        old = previous.get(identity(row))
        value = dict(row, intervalCPUPercent=None)
        if old and elapsed > 0 and row["cpuSeconds"] >= old["cpuSeconds"]:
            value["intervalCPUPercent"] = round(
                100 * (row["cpuSeconds"] - old["cpuSeconds"]) / elapsed, 2)
        result.append(value)
    return sorted(result, key=lambda row: row["intervalCPUPercent"] or 0, reverse=True)


def collect(folder, *, read=read_processes, run=subprocess.run,
            sleep=time.sleep, monotonic=time.monotonic, duration=3):
    first = read()
    if not first:
        raise RuntimeError("No running packaged Typeflux app found; this command never starts one.")
    started = monotonic()
    sleep(4)
    second = read()
    elapsed = monotonic() - started
    rows = cpu_deltas(first, second, elapsed)
    report = dict(generatedAt=datetime.now(timezone.utc).isoformat(),
                  measurementSeconds=elapsed, before=first, after=rows,
                  sampleLimit=MAX_PROCESSES, samples=[])
    for row in rows[:MAX_PROCESSES]:
        item = dict(pid=row["pid"], role=row["role"])
        report["samples"].append(item)
        # Recheck the start time and command: PIDs can be reused during collection.
        if not any(identity(current) == identity(row) for current in read()):
            item["status"] = "exited-or-replaced"
            continue
        name = f"{row['role']}-{row['pid']}.txt"
        target = folder / name
        print(f"Sampling {row['role']} (PID {row['pid']})...", flush=True)
        try:
            result = run(["/usr/bin/sample", str(row["pid"]), str(duration),
                          "-file", str(target)], capture_output=True, text=True,
                         timeout=duration + 10)
            item["status"] = "ok" if result.returncode == 0 and target.exists() else "failed"
            # Do not copy arbitrary tool output (or other processes' commands) into reports.
            item["exitCode"] = result.returncode
        except (subprocess.TimeoutExpired, OSError):
            item["status"] = "timeout-or-unavailable"
        if target.exists():
            limit = 8 * 1024 * 1024
            with target.open("r+b") as stream:
                if stream.seek(0, 2) > limit:
                    stream.truncate(limit)
                    item["truncated"] = True
            item["file"] = name
            target.chmod(0o600)
    (folder / "processes.json").write_text(json.dumps(report, indent=2) + "\n")
    (folder / "processes.json").chmod(0o600)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    folder = Path(tempfile.mkdtemp(prefix="typeflux-idle-cpu-"))
    try:
        collect(folder)
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Collection failed: {error}\nPartial output: {folder}\n")
    # mkstemp prevents a permissive archive window or following a pre-existing symlink.
    descriptor, temporary = tempfile.mkstemp(prefix="typeflux-idle-cpu-", suffix=".tar.gz")
    os.close(descriptor)
    archive = Path(temporary)
    with tarfile.open(archive, "w:gz") as bundle:
        bundle.add(folder, arcname=folder.name)
    print(f"Collected without starting or stopping Typeflux. Archive: {archive}")
    print("Stacks include local file paths and loaded libraries; review before sharing.")


if __name__ == "__main__":
    main()
