#!/usr/bin/env python3
"""Run local ASR benchmarks for Typeflux mixed Chinese/English samples."""

from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODELS_ROOT = Path.home() / "Library/Application Support/Typeflux/LocalModels"
DEFAULT_OUTPUT_DIR = REPO_ROOT / "reports/local-asr-benchmark"

MODEL_DEFINITIONS = {
    "senseVoiceSmall": {
        "label": "SenseVoice Small",
        "required": [
            "sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts/bin/sherpa-onnx-offline",
            "sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts/lib/libsherpa-onnx-c-api.dylib",
            "sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts/lib/libonnxruntime.dylib",
            "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/model.int8.onnx",
            "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/tokens.txt",
        ],
    },
    "qwen3ASR": {
        "label": "Qwen3-ASR 0.6B int8",
        "required": [
            "sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts/bin/sherpa-onnx-offline",
            "sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts/lib/libsherpa-onnx-c-api.dylib",
            "sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts/lib/libonnxruntime.dylib",
            "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/conv_frontend.onnx",
            "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/encoder.int8.onnx",
            "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/decoder.int8.onnx",
            "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/tokenizer",
        ],
    },
    "whisperLocal": {
        "label": "WhisperKit Medium",
        "required": [],
    },
}


@dataclass(frozen=True)
class Sample:
    sample_id: str
    audio_file: Path
    reference: str
    expected_terms: list[str]
    protected_terms: list[str]


def normalize_text(value: str) -> str:
    folded = unicodedata.normalize("NFKC", value).lower()
    return "".join(ch for ch in folded if not ch.isspace())


def levenshtein_distance(left: str, right: str) -> int:
    if left == right:
        return 0
    if not left:
        return len(right)
    if not right:
        return len(left)

    previous = list(range(len(right) + 1))
    for i, left_char in enumerate(left, start=1):
        current = [i]
        for j, right_char in enumerate(right, start=1):
            insertion = current[j - 1] + 1
            deletion = previous[j] + 1
            substitution = previous[j - 1] + (left_char != right_char)
            current.append(min(insertion, deletion, substitution))
        previous = current
    return previous[-1]


def term_recall(transcript: str, terms: list[str], *, exact: bool) -> dict[str, Any]:
    if not terms:
        return {"matched": [], "missing": [], "score": None}

    haystack = transcript if exact else normalize_text(transcript)
    matched: list[str] = []
    missing: list[str] = []
    for term in terms:
        needle = term if exact else normalize_text(term)
        if needle and needle in haystack:
            matched.append(term)
        else:
            missing.append(term)
    return {
        "matched": matched,
        "missing": missing,
        "score": len(matched) / len(terms),
    }


def transcript_metrics(reference: str, transcript: str, expected_terms: list[str], protected_terms: list[str]) -> dict[str, Any]:
    normalized_reference = normalize_text(reference)
    normalized_transcript = normalize_text(transcript)
    distance = levenshtein_distance(normalized_reference, normalized_transcript)
    denominator = max(len(normalized_reference), 1)
    return {
        "wholeTranscriptDistance": distance,
        "wholeTranscriptDistanceRatio": distance / denominator,
        "expectedTermRecall": term_recall(transcript, dedupe(expected_terms), exact=False),
        "protectedTermExactMatch": term_recall(transcript, dedupe(protected_terms), exact=True),
    }


def dedupe(values: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        if value not in seen:
            result.append(value)
            seen.add(value)
    return result


def load_manifest(path: Path, audio_root: Path | None) -> list[Sample]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    root = audio_root or path.parent
    global_terms = payload.get("protectedTerms", [])
    samples: list[Sample] = []
    for item in payload.get("samples", []):
        sample_id = item["id"]
        reference = item["reference"]
        expected_terms = list(item.get("expectedTerms", []))
        protected_terms = list(item.get("protectedTerms", global_terms))
        audio_file = root / item["audioFile"]
        samples.append(Sample(sample_id, audio_file, reference, expected_terms, protected_terms))
    if not samples:
        raise ValueError(f"Manifest has no samples: {path}")
    return samples


def model_storage_info(model: str, models_root: Path) -> tuple[str | None, Path | None, list[str]]:
    record_path = models_root / model / "prepared.json"
    if not record_path.exists():
        return None, None, [f"missing prepared record: {record_path}"]

    try:
        record = json.loads(record_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        return None, None, [f"invalid prepared record {record_path}: {error}"]

    storage_path = Path(record.get("storagePath", ""))
    if not storage_path.exists():
        return record.get("modelIdentifier"), storage_path, [f"missing storage path: {storage_path}"]

    missing = []
    for relative in MODEL_DEFINITIONS[model]["required"]:
        candidate = storage_path / relative
        if not candidate.exists():
            missing.append(f"missing asset: {candidate}")

    if model == "whisperLocal" and not any(storage_path.iterdir()):
        missing.append(f"empty WhisperKit storage path: {storage_path}")

    return record.get("modelIdentifier"), storage_path, missing


def directory_size_bytes(path: Path | None) -> int | None:
    if path is None or not path.exists():
        return None
    total = 0
    for item in path.rglob("*"):
        if item.is_file():
            total += item.stat().st_size
    return total


def make_input_directory(samples: list[Sample], target: Path) -> dict[str, Sample]:
    target.mkdir(parents=True, exist_ok=True)
    mapping: dict[str, Sample] = {}
    for sample in samples:
        if not sample.audio_file.exists():
            raise FileNotFoundError(f"missing audio file for {sample.sample_id}: {sample.audio_file}")
        link_name = f"{sample.sample_id}{sample.audio_file.suffix.lower() or '.wav'}"
        link_path = target / link_name
        if link_path.exists():
            link_path.unlink()
        os.symlink(sample.audio_file, link_path)
        mapping[link_name] = sample
    return mapping


def run_typeflux_batch(model: str, input_dir: Path, output_csv: Path, package_path: Path, typeflux_bin: str | None) -> tuple[int, str]:
    if typeflux_bin:
        command = [typeflux_bin, "batch-wav"]
    else:
        command = ["swift", "run", "--package-path", str(package_path), "Typeflux", "batch-wav"]

    command += [
        "--input",
        str(input_dir),
        "--output",
        str(output_csv),
        "--stt-provider",
        "localModel",
        "--local-stt-model",
        model,
        "--no-persona",
    ]

    suite = f"ai.gulu.app.typeflux.local-asr-benchmark.{os.getpid()}.{model}"
    env = os.environ.copy()
    env["TYPEFLUX_BUNDLE_IDENTIFIER"] = env.get("TYPEFLUX_BUNDLE_IDENTIFIER", "ai.gulu.app.typeflux")
    env["TYPEFLUX_USER_DEFAULTS_SUITE"] = suite
    if sys.platform == "darwin":
        subprocess.run(["defaults", "write", suite, "stt.local.autoSetup", "-bool", "false"], check=False)

    completed = subprocess.run(command, text=True, capture_output=True, env=env, check=False)

    if sys.platform == "darwin":
        subprocess.run(["defaults", "delete", suite], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    combined_output = "\n".join(part for part in [completed.stdout, completed.stderr] if part)
    return completed.returncode, combined_output


def read_batch_csv(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def aggregate_scores(sample_results: list[dict[str, Any]]) -> dict[str, Any]:
    completed = [row for row in sample_results if row["status"] == "completed"]
    if not completed:
        return {
            "sampleCount": len(sample_results),
            "completedCount": 0,
            "averageRuntimeMilliseconds": None,
            "averageWholeTranscriptDistanceRatio": None,
            "averageExpectedTermRecall": None,
            "averageProtectedTermExactMatch": None,
        }

    def average(values: list[float]) -> float | None:
        return sum(values) / len(values) if values else None

    return {
        "sampleCount": len(sample_results),
        "completedCount": len(completed),
        "averageRuntimeMilliseconds": average([row["runtimeMilliseconds"] for row in completed if row["runtimeMilliseconds"] is not None]),
        "averageWholeTranscriptDistanceRatio": average([
            row["metrics"]["wholeTranscriptDistanceRatio"] for row in completed
        ]),
        "averageExpectedTermRecall": average([
            row["metrics"]["expectedTermRecall"]["score"]
            for row in completed
            if row["metrics"]["expectedTermRecall"]["score"] is not None
        ]),
        "averageProtectedTermExactMatch": average([
            row["metrics"]["protectedTermExactMatch"]["score"]
            for row in completed
            if row["metrics"]["protectedTermExactMatch"]["score"] is not None
        ]),
    }


def benchmark_model(
    model: str,
    samples: list[Sample],
    work_dir: Path,
    package_path: Path,
    typeflux_bin: str | None,
    models_root: Path,
) -> dict[str, Any]:
    identifier, storage_path, missing_assets = model_storage_info(model, models_root)
    base = {
        "model": model,
        "label": MODEL_DEFINITIONS[model]["label"],
        "modelIdentifier": identifier,
        "storagePath": str(storage_path) if storage_path else None,
        "footprintBytes": directory_size_bytes(storage_path),
    }
    if missing_assets:
        return {
            **base,
            "status": "skipped",
            "diagnostics": missing_assets,
            "aggregate": {
                "sampleCount": len(samples),
                "completedCount": 0,
                "averageRuntimeMilliseconds": None,
                "averageWholeTranscriptDistanceRatio": None,
                "averageExpectedTermRecall": None,
                "averageProtectedTermExactMatch": None,
            },
            "samples": [],
        }

    input_dir = work_dir / model / "input"
    output_csv = work_dir / model / "batch.csv"
    input_mapping = make_input_directory(samples, input_dir)

    started = time.monotonic()
    exit_code, command_output = run_typeflux_batch(model, input_dir, output_csv, package_path, typeflux_bin)
    elapsed_ms = int((time.monotonic() - started) * 1000)
    rows = read_batch_csv(output_csv)

    sample_results: list[dict[str, Any]] = []
    for row in rows:
        sample = input_mapping.get(row.get("file", ""))
        if sample is None:
            continue
        transcript = row.get("transcript", "")
        status = "completed" if row.get("status") == "completed" else "failed"
        metrics = transcript_metrics(sample.reference, transcript, sample.expected_terms, sample.protected_terms)
        runtime = int(row["stt_ms"]) if row.get("stt_ms", "").isdigit() else None
        sample_results.append({
            "id": sample.sample_id,
            "audioFile": str(sample.audio_file),
            "status": status,
            "reference": sample.reference,
            "transcript": transcript,
            "runtimeMilliseconds": runtime,
            "metrics": metrics,
            "error": row.get("error") or None,
        })

    seen_ids = {row["id"] for row in sample_results}
    for sample in samples:
        if sample.sample_id not in seen_ids:
            sample_results.append({
                "id": sample.sample_id,
                "audioFile": str(sample.audio_file),
                "status": "failed",
                "reference": sample.reference,
                "transcript": "",
                "runtimeMilliseconds": None,
                "metrics": transcript_metrics(sample.reference, "", sample.expected_terms, sample.protected_terms),
                "error": "No result row produced by Typeflux batch-wav.",
            })

    status = "completed" if exit_code == 0 and all(row["status"] == "completed" for row in sample_results) else "failed"
    return {
        **base,
        "status": status,
        "diagnostics": [line for line in command_output.splitlines() if line.strip()][-20:],
        "elapsedMilliseconds": elapsed_ms,
        "aggregate": aggregate_scores(sample_results),
        "samples": sorted(sample_results, key=lambda row: row["id"]),
    }


def write_summary(report: dict[str, Any], path: Path) -> None:
    lines = [
        "# Local ASR Benchmark Summary",
        "",
        f"- Manifest: `{report['manifestPath']}`",
        f"- Generated at: `{report['generatedAt']}`",
        "",
        "| Model | Status | Samples | Avg runtime ms | Distance ratio | Term recall | Protected exact | Footprint |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for model in report["models"]:
        aggregate = model["aggregate"]
        lines.append(
            "| {label} | {status} | {completed}/{total} | {runtime} | {distance} | {recall} | {exact} | {footprint} |".format(
                label=model["label"],
                status=model["status"],
                completed=aggregate["completedCount"],
                total=aggregate["sampleCount"],
                runtime=format_number(aggregate["averageRuntimeMilliseconds"], 0),
                distance=format_number(aggregate["averageWholeTranscriptDistanceRatio"], 3),
                recall=format_number(aggregate["averageExpectedTermRecall"], 3),
                exact=format_number(aggregate["averageProtectedTermExactMatch"], 3),
                footprint=format_bytes(model["footprintBytes"]),
            )
        )
    lines.append("")
    lines.append("Skipped models are expected when local assets are not prepared on this Mac.")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def format_number(value: float | None, digits: int) -> str:
    if value is None:
        return ""
    return f"{value:.{digits}f}"


def format_bytes(value: int | None) -> str:
    if value is None:
        return ""
    for unit in ["B", "KB", "MB", "GB"]:
        if value < 1024 or unit == "GB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{value} B"
        value = int(value / 1024)
    return str(value)


def run_self_test() -> int:
    metrics = transcript_metrics(
        "Typeflux 支持 OpenAI API 和 async await",
        "Typeflux 支持 OpenAI API 和 async await",
        ["Typeflux", "OpenAI", "API", "async await"],
        ["Typeflux", "OpenAI", "API"],
    )
    assert metrics["wholeTranscriptDistance"] == 0
    assert metrics["expectedTermRecall"]["score"] == 1
    assert metrics["protectedTermExactMatch"]["score"] == 1

    metrics = transcript_metrics(
        "SwiftUI calls URLSession",
        "swift ui calls url session",
        ["SwiftUI", "URLSession"],
        ["SwiftUI", "URLSession"],
    )
    assert metrics["expectedTermRecall"]["score"] == 1
    assert metrics["protectedTermExactMatch"]["score"] == 0

    print("local_asr_benchmark.py self-test passed")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=REPO_ROOT / "docs/local-asr-benchmark-manifest.json")
    parser.add_argument("--audio-root", type=Path, default=None)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--models-root", type=Path, default=DEFAULT_MODELS_ROOT)
    parser.add_argument("--package-path", type=Path, default=REPO_ROOT)
    parser.add_argument("--typeflux-bin", default=None, help="Optional prebuilt Typeflux executable path.")
    parser.add_argument("--models", nargs="+", default=["senseVoiceSmall", "qwen3ASR", "whisperLocal"])
    parser.add_argument("--keep-work", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        return run_self_test()

    unknown_models = [model for model in args.models if model not in MODEL_DEFINITIONS]
    if unknown_models:
        raise ValueError(f"Unsupported model(s): {', '.join(unknown_models)}")

    samples = load_manifest(args.manifest, args.audio_root)
    args.output_dir.mkdir(parents=True, exist_ok=True)

    work_parent = Path(tempfile.mkdtemp(prefix="typeflux-local-asr-benchmark-"))
    try:
        models = [
            benchmark_model(model, samples, work_parent, args.package_path, args.typeflux_bin, args.models_root)
            for model in args.models
        ]
        report = {
            "version": 1,
            "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "manifestPath": str(args.manifest.resolve()),
            "modelsRoot": str(args.models_root),
            "models": models,
        }
        report_path = args.output_dir / "report.json"
        summary_path = args.output_dir / "summary.md"
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        write_summary(report, summary_path)
        print(f"JSON report written: {report_path}")
        print(f"Summary written: {summary_path}")
    finally:
        if args.keep_work:
            print(f"Work directory kept: {work_parent}")
        else:
            shutil.rmtree(work_parent, ignore_errors=True)

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"Error: {error}", file=sys.stderr)
        raise SystemExit(1)
