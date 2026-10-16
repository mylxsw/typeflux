#!/usr/bin/env python3
"""Foreground, sequential HTML-reader resource probe; never an input-to-UI benchmark."""
import argparse
import json
import math
import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", type=Path, required=True)
parser.add_argument("--fixture", type=Path, required=True)
parser.add_argument("--seconds", type=float, default=300)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
folder = Path(__file__).resolve().parent
snapshot = tempfile.TemporaryDirectory(prefix="typeflux-html-probe-")
input_root = Path(snapshot.name).resolve()
shutil.copyfile(args.fixture, input_root / "body.html")
scope = {"roots": [str(input_root)], "excludedPaths": [], "excludedFolderNames": [],
         "excludedExtensions": [], "includeHidden": False, "blocked": []}
request = {"operation": "content", "path": str(input_root / "body.html"),
           "scope": scope, "blocked": [], "readText": True, "cursor": {"page": 0, "offset": 0}}
wire = (json.dumps(request) + "\n").encode()
rows, timings, buffer = [], [], b""
started = time.monotonic()
error = None
stderr_path = args.output.with_suffix(".stderr.log")
with stderr_path.open("w") as stderr:
    process = subprocess.Popen(["/usr/bin/nice", "-n", "10", str(args.binary.resolve()), "file-index-worker"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr)
    try:
        while time.monotonic() - started < args.seconds:
            before = time.monotonic()
            process.stdin.write(wire)
            process.stdin.flush()
            deadline = before + 15
            while True:
                if b"\n" not in buffer:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
                        raise TimeoutError("HTML response exceeded 15 seconds")
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        raise RuntimeError("HTML worker exited unexpectedly")
                    buffer += chunk
                    continue
                line, buffer = buffer.split(b"\n", 1)
                result = json.loads(line)
                if result.get("more") is True:
                    continue
                if result.get("error") is not None:
                    raise RuntimeError("Reader error code " + str(result["error"]))
                if "INV-682914" not in result["pages"][0]["text"]:
                    raise RuntimeError("Synthetic HTML identifier missing")
                break
            timings.append((time.monotonic() - before) * 1000)
            memory = subprocess.check_output(["ps", "-p", str(process.pid), "-o", "rss=,%cpu="], text=True).split()
            rows.append({"seconds": time.monotonic() - started, "rss_bytes": int(memory[0]) * 1024,
                         "cpu_percent": float(memory[1])})
            time.sleep(0.1)
    except Exception as failure:
        error = type(failure).__name__ + ": " + str(failure)
    finally:
        process.stdin.close()
        try:
            code = process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            code = process.wait(timeout=5)
        snapshot.cleanup()

def percentile(fraction):
    ordered = sorted(timings)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)] if ordered else None

report = {"wall_seconds": time.monotonic() - started, "worker_exit_code": code, "error": error,
          "samples": len(timings), "missing_identifier": 0 if error is None else None,
          "milliseconds": {"p50": percentile(.5), "p95": percentile(.95), "p99": percentile(.99)},
          "peak_rss_bytes": max((row["rss_bytes"] for row in rows), default=0),
          "scope": "Debug instrumented production file-index-worker, nice 10, sequential repeated extraction of the same synthetic HTML body, 100 ms between requests. No embedding, background scheduler, UI input, GPU counters or long-term thermal acceptance measured. RSS is ps resident pages; CPU percent is ps lifetime average, 100 percent per core.",
          "request_milliseconds": timings, "resources": rows}
args.output.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({key: value for key, value in report.items() if key not in {"resources", "request_milliseconds"}}))
raise SystemExit(0 if error is None and code == 0 and timings else 1)
