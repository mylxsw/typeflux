#!/usr/bin/env python3
"""Extract the build IDs from the exact application bundles being published."""

import json
import plistlib
import re
import sys
from pathlib import Path
from zipfile import ZipFile


def read_manifest(directory: Path, tag: str, channel: str) -> dict:
    builds = []
    versions = set()
    seen = set()
    for variant in ("app-only", "full", "minimal"):
        for architecture in ("apple-silicon", "intel"):
            name = f"Typeflux-{variant}-{architecture}.zip"
            with ZipFile(directory / name) as archive:
                info = plistlib.loads(archive.read("Typeflux.app/Contents/Info.plist"))
            version = info["CFBundleShortVersionString"]
            build_id = info["TypefluxBuildID"]
            if not re.fullmatch(rf"{channel}-[0-9a-f]{{8}}(?:-[0-9a-f]{{4}}){{3}}-[0-9a-f]{{12}}", build_id):
                raise ValueError(f"{name} has an invalid {channel} build ID")
            if build_id in seen:
                raise ValueError(f"{name} reuses a build ID")
            seen.add(build_id)
            versions.add(version)
            builds.append({"file": name, "id": build_id})
    if len(versions) != 1 or (channel == "stable" and versions != {tag.removeprefix("v")}):
        raise ValueError(f"Bundle versions {sorted(versions)} disagree with release {tag}")
    return {"version": versions.pop(), "channel": channel, "builds": builds}


if __name__ == "__main__":
    root, release_tag, release_channel = sys.argv[1:]
    directory = Path(root)
    manifest = read_manifest(directory, release_tag, release_channel)
    (directory / "typeflux-builds.json").write_text(json.dumps(manifest, indent=2) + "\n")
