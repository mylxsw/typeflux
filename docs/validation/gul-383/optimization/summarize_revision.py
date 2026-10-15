#!/usr/bin/env python3
"""Validate and summarize the revision's real contention artifacts; nearest-rank percentiles."""
import collections
import json
import math
from pathlib import Path

root = Path(__file__).resolve().parent
native = json.loads((root / "native-inference-contention.json").read_text())
media = json.loads((root / "real-media-priority.json").read_text())
resources = json.loads((root / "revision-release-resources.json").read_text())
assert native["build"] == media["build"] == "Release"
assert resources["exit_code"] == 0
assert media["segment_times"] == [0, 30, 60] and media["transcript_nonempty"]
assert media["segments"][1]["start_uptime"] >= media["document_publish_uptime"]
assert media["document_publish_uptime"] > media["transcription_end_uptime"]
groups = collections.defaultdict(list)
for row in native["rows"]:
    assert len(row["overlapping_batch"]) == 2
    assert row["overlapping_batch"][0] <= row["input_uptime"] <= row["overlapping_batch"][1]
    groups[row["entry"], row["scenario"]].append(row)


def stats(values):
    values = sorted(values)
    return {"n": len(values), **{f"p{p}": values[math.ceil(p / 100 * len(values)) - 1] for p in (50, 95, 99)},
            "max": values[-1]}


summary = {"definition": "Nearest-rank milliseconds. Timer gap percentiles are distributions of each query's largest polling/accessibility gap, not frame intervals.",
           "groups": {}, "resources": {"wall_seconds": resources["wall_seconds"], "peak_rss_by_name_bytes": {}},
           "media": media}
assert len(groups) == 4
for (entry, scenario), rows in sorted(groups.items()):
    assert len(rows) >= 100 and len({row["round"] for row in rows}) == len(rows)
    summary["groups"][entry + "/" + scenario] = {
        key: stats([row[key] for row in rows]) for key in
        ("input_to_publish_ms", "input_to_draw_ms", "complete_ms", "main_actor_max_timer_gap_ms")}
    summary["groups"][entry + "/" + scenario]["remaining_active_batch_ms"] = stats([
        (row["overlapping_batch"][1] - row["input_uptime"]) * 1000 for row in rows])
for row in resources["samples"]:
    for name, values in row["rss_bytes"].items():
        previous = summary["resources"]["peak_rss_by_name_bytes"].get(name, 0)
        summary["resources"]["peak_rss_by_name_bytes"][name] = max(previous, sum(values))
summary["resources"]["max_simultaneous_sampled_rss_bytes"] = max(
    sum(sum(values) for values in row["rss_bytes"].values()) for row in resources["samples"])
summary["resources"]["app_getrusage_peak_bytes"] = native["app_max_rss_bytes"]
summary["resources"]["definition"] = resources["rss_definition"]
summary["entries"] = [{key: value for key, value in entry.items() if key != "index_intervals"}
                      for entry in native["entries"]]
(root / "revision-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps({key: {metric: round(value["p95"], 2) for metric, value in row.items()}
                  for key, row in summary["groups"].items()}, indent=2))
