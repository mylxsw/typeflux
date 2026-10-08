#!/usr/bin/env python3
"""Import every Lobe Icons model logo from a verified, pinned checkout."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

PINNED_REVISION = "c385b2b8d1f9e19aa86e628d4e23c91ee1111a47"
ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "Packages/TypefluxChat/Sources/TypefluxChat/Resources/ModelIcons"
# These provider-classified logos also identify model families or provide fallbacks.
SUPPLEMENTAL = {"OpenAI", "Kimi", "Moonshot", "Meta", "ZAI", "Anthropic", "Google",
                "Cohere", "Microsoft", "Nvidia", "Stability", "OpenRouter", "Ollama", "Groq"}
# Kimi's color artwork has a fixed white wordmark, invisible on light surfaces.
MONOCHROME = {"Kimi"}


def collect(source, revision):
    actual = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if actual != revision:
        raise ValueError(f"Expected upstream {revision}, found {actual}")
    if subprocess.check_output(["git", "-C", str(source), "status", "--porcelain"], text=True).strip():
        raise ValueError("Upstream checkout must be clean")
    toc = json.loads((source / "src/toc.json").read_text())
    entries, files = [], {}
    for item in sorted(toc, key=lambda row: row["id"].lower()):
        if item["group"] != "model" and item["id"] not in SUPPLEMENTAL:
            continue
        key = item["id"].lower()
        monochrome = not item["param"]["hasColor"] or item["id"] in MONOCHROME
        filename = key + ("" if monochrome else "-color") + ".png"
        hashes = {}
        for theme in ("light", "dark"):
            data = (source / "packages/static-png" / theme / filename).read_bytes()
            if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                raise ValueError(f"Invalid PNG: {filename}")
            name = f"{key}-{theme}.png"
            files[name] = data
            hashes[theme] = hashlib.sha256(data).hexdigest()
        entries.append(dict(key=key, title=item["title"], group=item["group"],
                            monochrome=monochrome, sha256=hashes))
    manifest = dict(source="https://github.com/lobehub/lobe-icons", revision=revision, icons=entries)
    files["catalog.json"] = (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode()
    files["LICENSE"] = (source / "LICENSE").read_bytes()
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path, help="Clean lobe-icons git checkout")
    parser.add_argument("--revision", default=PINNED_REVISION, help="Explicit commit for an intentional update")
    parser.add_argument("--check", action="store_true", help="Verify committed assets without modifying files")
    args = parser.parse_args()
    files = collect(args.source.resolve(), args.revision)
    existing = {path.name for path in DESTINATION.glob("*.png")} | {"catalog.json", "LICENSE"}
    added, removed = files.keys() - existing, existing - files.keys()
    changed = {name for name, data in files.items()
               if not (DESTINATION / name).exists() or (DESTINATION / name).read_bytes() != data}
    print(f"Added: {sorted(added)}; removed: {sorted(removed)}; changed: {len(changed)}")
    if args.check:
        if changed or removed:
            raise SystemExit("Model icon assets are out of sync")
        return
    DESTINATION.mkdir(parents=True, exist_ok=True)
    for name in removed:
        (DESTINATION / name).unlink()
    for name, data in files.items():
        (DESTINATION / name).write_bytes(data)


if __name__ == "__main__":
    main()
