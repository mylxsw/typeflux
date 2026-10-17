#!/usr/bin/env python3
"""Read-only bundle structure evidence. Never executes, signs or launches bundled code."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
from xml.parsers.expat import ExpatError

GATES = (
    "packaging_and_identity", "microphone_permission", "device_lifecycle",
    "quit_and_collection", "audio_performance", "local_inference_and_translation",
    "hotkey_capture_sync",
)


def member(root, relative, directory=False):
    path = root
    for part in Path(relative).parts:
        path = path / part
        if path.is_symlink():
            raise ValueError(f"Symlink is not accepted in audited member: {relative}")
    mode = path.stat().st_mode
    if not (stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode)):
        raise ValueError(f"Wrong bundle member type: {relative}")
    return path


def fingerprint(path, maximum_bytes=2 * 1024**3):
    before = path.stat()
    if before.st_size <= 0 or before.st_size > maximum_bytes:
        raise ValueError(f"Empty or oversized member: {path.name}")
    digest = hashlib.sha256()
    total = 0
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            total += len(chunk)
            if total > maximum_bytes:
                raise ValueError(f"Member grew beyond bound: {path.name}")
            digest.update(chunk)
        after = os.fstat(stream.fileno())
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
        after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns
    ):
        raise ValueError(f"Member changed during inspection: {path.name}")
    return {"bytes": total, "sha256": digest.hexdigest()}


def inspect_bundle(app, architecture, source_commit):
    if architecture not in ("arm64", "x86_64", "universal"):
        raise ValueError("Expected an explicit release architecture")
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise ValueError("Expected a full source commit, not a branch or abbreviation")
    if app.is_symlink() or not app.is_dir():
        raise ValueError("Expected a stable app directory, not a symlink")
    info_path = member(app, "Contents/Info.plist")
    info_hash = fingerprint(info_path, 1024 * 1024)
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    if not isinstance(info, dict) or info.get("CFBundleIdentifier") != "ai.gulu.app.typeflux":
        raise ValueError("Unexpected application identity")
    if info.get("CFBundleExecutable") != "Typeflux":
        raise ValueError("Unexpected main executable")
    if not isinstance(info.get("NSMicrophoneUsageDescription"), str) or not info["NSMicrophoneUsageDescription"].strip():
        raise ValueError("Missing microphone purpose declaration")
    binaries = ["Contents/MacOS/Typeflux", "Contents/Helpers/TypefluxInferenceHelper",
                "Contents/Helpers/TypefluxMediaHelper"]
    # Mirrors build_release.sh: the semantic runtime is omitted for Intel releases.
    if architecture != "x86_64":
        binaries.append("Contents/Resources/LocalRuntimes/SemanticSearch/TypefluxSemanticHelper")
    files = {"Contents/Info.plist": info_hash}
    for relative in binaries:
        path = member(app, relative)
        if path.stat().st_mode & 0o111 == 0:
            raise ValueError(f"Member is not executable: {relative}")
        files[relative] = fingerprint(path)
    resource = "Contents/Helpers/swift-transformers_Hub.bundle"
    directory = member(app, resource, directory=True)
    resource_count = resource_bytes = 0
    for parent, directories, names in os.walk(directory, followlinks=False):
        for name in directories:
            member(app, str((Path(parent) / name).relative_to(app)), directory=True)
        for name in names:
            relative = str((Path(parent) / name).relative_to(app))
            path = member(app, relative)
            resource_count += 1
            if resource_count > 10000:
                raise ValueError("Tokenizer resource file count exceeds inspection bound")
            item = fingerprint(path, 256 * 1024**2)
            resource_bytes += item["bytes"]
            if resource_bytes > 256 * 1024**2:
                raise ValueError("Tokenizer resources exceed inspection byte bound")
            files[relative] = item
    if not resource_count:
        raise ValueError("Tokenizer resource bundle is empty")
    return {
        "schema_version": 1, "structure_status": "pass", "stage4_accepted": False,
        "source_commit_claim": source_commit, "requested_architecture": architecture,
        "identity": info["CFBundleIdentifier"], "files": dict(sorted(files.items())),
        "manual_gates": {gate: "not_verified" for gate in GATES},
        "limits": ["No signature, notarization, Mach-O architecture or OS compatibility verification.",
                   "Source commit is supplied by the operator; hashes do not prove build provenance.",
                   "No TCC, capture, device, model, network or UI execution.",
                   "Inspect a stable private package; this is not a concurrent filesystem transaction."],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--architecture", choices=["arm64", "x86_64", "universal"], required=True)
    parser.add_argument("--source-commit", required=True)
    args = parser.parse_args()
    try:
        report = inspect_bundle(args.app, args.architecture, args.source_commit)
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError) as error:
        report = {"schema_version": 1, "structure_status": "fail", "stage4_accepted": False,
                  "error": (f"Filesystem inspection failed (errno {error.errno})" if isinstance(error, OSError)
                            else str(error)), "manual_gates": {gate: "not_verified" for gate in GATES}}
    print(json.dumps(report, indent=2))
    return 0 if report["structure_status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
