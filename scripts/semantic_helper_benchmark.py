#!/usr/bin/env python3
"""Measure pinned local helper IPC without reading user files or logging query contents."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import resource
import select
import subprocess
import time

MODEL_SHA256 = "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135"


def percentile(values, quantile):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * quantile))]


def measure(helper, model, samples=100):
    if samples < 100:
        raise ValueError("At least 100 warm samples are required")
    with model.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != MODEL_SHA256:
            raise ValueError("Unexpected model checksum")
    process = subprocess.Popen([str(helper.resolve()), str(model.resolve())], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    values, timings, buffer = [], [], b""
    started = time.monotonic()
    try:
        for index in range(samples + 1):
            query = ("项目费用报销需要哪些材料 " if index % 2 else "How can I claim the expenses for project ") + str(index)
            request = {"texts": ["task: search result | query: " + query]}
            begin = time.monotonic()
            process.stdin.write(json.dumps(request).encode() + b"\n")
            process.stdin.flush()
            deadline = begin + 30
            while b"\n" not in buffer:
                if not select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))[0]:
                    raise TimeoutError("Helper response deadline")
                block = os.read(process.stdout.fileno(), 65536)
                if not block:
                    raise ValueError("Helper exited before a response")
                buffer += block
            line, buffer = buffer.split(b"\n", 1)
            response = json.loads(line)
            vector = response.get("embeddings", [[]])[0]
            if (len(vector) != 768 or not all(math.isfinite(value) for value in vector)
                    or abs(sum(value * value for value in vector) - 1) > 0.02):
                raise ValueError("Invalid embedding")
            values.append((time.monotonic() - begin) * 1000)
            timings.append(response.get("semanticTiming"))
        process.stdin.close()
        process.wait(timeout=10)
        if process.returncode:
            raise ValueError("Helper exited with failure")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=10)
        process.stdout.close()
        if not process.stdin.closed:
            process.stdin.close()
    rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    return {"scope": "Release helper IPC only, excluding app scheduling, retrieval, permissions and UI",
            "hardware": platform.machine(), "model_sha256": MODEL_SHA256, "samples": samples,
            "cold_ms": values[0], "warm_p50_ms": percentile(values[1:], 0.5),
            "warm_p95_ms": percentile(values[1:], 0.95), "warm_p99_ms": percentile(values[1:], 0.99),
            "samples_ms": values, "helper_timings": timings, "indexing_concurrency": 0,
            "child_max_rss_bytes": rss if platform.system() == "Darwin" else rss * 1024,
            "wall_seconds": time.monotonic() - started}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=100)
    args = parser.parse_args()
    report = measure(args.helper, args.model, args.samples)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key not in {"samples_ms", "helper_timings"}}))


if __name__ == "__main__":
    main()
