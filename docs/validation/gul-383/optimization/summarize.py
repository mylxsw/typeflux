#!/usr/bin/env python3
"""Summarize the checked-in synthetic regression measurements without dropping failed queries."""
from collections import defaultdict
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def distribution(values):
    ordered = sorted(values)
    return {"n": len(values), **{
        "p" + str(int(q * 100)): ordered[math.ceil(len(ordered) * q) - 1] if ordered else None
        for q in [0.5, 0.95, 0.99]
    }}


def latency(name, dimensions, metrics):
    data = json.loads((ROOT / name).read_text())
    groups = defaultdict(list)
    for row in data["rows"]:
        groups[tuple(row[key] for key in dimensions)].append(row)
    result = []
    for group, rows in groups.items():
        item = dict(zip(dimensions, group))
        item["samples"] = len(rows)
        for metric in metrics:
            item[metric] = distribution([row[metric] for row in rows if row[metric] is not None])
            item[metric]["missing"] = sum(row[metric] is None for row in rows)
        if "events" in rows[0]:
            stages = defaultdict(list)
            for row in rows:
                events = {event["stage"]: event["milliseconds"] for event in row["events"]}
                for start, end, title in [("vector-start", "vector-end", "vector_ms"),
                                          ("fts-start", "fts-end", "fts_ms"),
                                          ("helper-enqueued", "helper-queue-end", "helper_queue_ms")]:
                    if start in events and end in events:
                        stages[title].append(events[end] - events[start])
                for event in row["events"]:
                    if event["duration"]:
                        stages[event["stage"]].append(event["milliseconds"])
            item["stages"] = {key: distribution(values) for key, values in stages.items()}
        result.append(item)
    return {"metadata": {key: value for key, value in data.items() if key != "rows"}, "groups": result}


def main():
    result = {
        "percentile": "Nearest rank; missing hit counts are reported separately, never counted as fast successes.",
        "controller": latency("publication-latency.json", ["implementation", "entry", "scenario"],
                              ["first_hit_ms", "complete_ms", "main_actor_max_timer_gap_ms"]),
        "native": latency("native-publication-latency.json", ["entry", "scenario"],
                          ["input_to_publish_ms", "input_to_draw_ms", "complete_ms", "main_actor_max_timer_gap_ms"]),
    }
    (ROOT / "latency-summary.json").write_text(json.dumps(result, indent=2) + "\n")
    quality = defaultdict(list)
    for row in json.loads((ROOT / "evaluation.json").read_text())["rows"]:
        quality[row["group"]].append(row)
    summary = {}
    for group, rows in quality.items():
        answerable = rows[0]["answerable"]
        summary[group] = {"n": len(rows)}
        if answerable:
            summary[group].update(recall_at_5=sum(row["rank"] is not None for row in rows) / len(rows),
                                  mrr=sum(1 / row["rank"] if row["rank"] else 0 for row in rows) / len(rows))
        else:
            summary[group]["false_positive_rate"] = sum(bool(row["hits"]) for row in rows) / len(rows)
    (ROOT / "evaluation-summary.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()
