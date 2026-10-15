#!/usr/bin/env python3
"""Run one foreground validation command and sample only its descendant process RSS."""
import argparse
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--log", type=Path, required=True)
parser.add_argument("--report", type=Path, required=True)
parser.add_argument("command", nargs=argparse.REMAINDER)
args = parser.parse_args()
command = args.command[1:] if args.command[:1] == ["--"] else args.command
if not command:
    parser.error("a foreground command is required")
started = time.monotonic()
rows = []
with args.log.open("w") as log:
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
    while process.poll() is None:
        listing = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss=,comm="], text=True)
        parsed = [line.split(maxsplit=3) for line in listing.splitlines()]
        parsed = [row for row in parsed if len(row) == 4]
        children = {process.pid}
        while True:
            descendants = children | {int(pid) for pid, parent, _, _ in parsed if int(parent) in children}
            if descendants == children:
                break
            children = descendants
        relevant = {}
        for pid, _, rss, name in parsed:
            name = Path(name).name
            if int(pid) in children and name in {"xctest", "TypefluxPackageTests", "TypefluxSemanticHelper", "Typeflux", "sherpa-onnx-offline"}:
                relevant.setdefault(name, []).append(int(rss) * 1024)
        if relevant:
            rows.append({"seconds": time.monotonic() - started, "rss_bytes": relevant})
        time.sleep(0.5)
    code = process.wait()
report = {"wall_seconds": time.monotonic() - started, "exit_code": code, "sample_period_seconds": 0.5,
          "rss_definition": "ps resident pages, bytes; descendant validation processes only. Shared pages are double counted in sums. Compiler/build processes excluded.",
          "samples": rows}
args.report.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({key: value for key, value in report.items() if key != "samples"}))
raise SystemExit(code)
