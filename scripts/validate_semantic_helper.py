#!/usr/bin/env python3
"""Opt-in real-model smoke test; never downloads weights or reads user documents."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    started = time.monotonic()
    expected = "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135"
    with args.model.open("rb") as stream:
        assert hashlib.file_digest(stream, "sha256").hexdigest() == expected, "model checksum"
    documents = [
        "title: handbook.txt | text: Employees submit project expense reimbursement requests using the finance expense form. Attach receipts and obtain manager approval.",
        "title: plants.txt | text: Water the garden plants twice a week. Tomatoes need sunshine and rich soil.",
        "title: travel.txt | text: The train timetable lists departures and arrivals between London and Paris.",
    ]
    queries = ["How do I claim expenses for my project?", "项目费用报销需要什么？"]
    framed = documents + ["task: search result | query: " + query for query in queries]
    requests = [{"texts": framed}, {"texts": []}, {"texts": ["a" * 1801]}]
    result = subprocess.run([str(args.helper.resolve()), str(args.model.resolve())],
                            input="\n".join(json.dumps(value) for value in requests) + "\ninvalid\n",
                            text=True, capture_output=True, timeout=180, check=True)
    replies = [json.loads(line) for line in result.stdout.splitlines()]
    assert len(replies) == 4, "one response per request"
    assert replies[0]["semanticTiming"]["modelLoadMilliseconds"] > 0
    assert all(reply["semanticTiming"]["encodingMilliseconds"] >= 0 for reply in replies)
    assert all("modelLoadMilliseconds" not in reply["semanticTiming"] for reply in replies[1:])
    vectors = replies[0]["embeddings"]
    assert len(vectors) == len(framed)
    for vector in vectors:
        assert len(vector) == 768 and all(math.isfinite(value) for value in vector)
        assert abs(sum(value * value for value in vector) - 1) < 0.002
    scores = [[sum(a * b for a, b in zip(query, document)) for document in vectors[:3]] for query in vectors[3:]]
    assert all(row.index(max(row)) == 0 for row in scores), scores
    assert all(reply.get("error") for reply in replies[1:]), "invalid input is rejected"
    report = {"passed": True, "dimension": 768, "queries": len(queries), "scores": scores,
              "invalid_requests_rejected": 3, "wall_seconds": round(time.monotonic() - started, 2)}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
