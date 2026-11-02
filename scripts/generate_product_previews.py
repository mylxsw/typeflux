#!/usr/bin/env python3
"""Create lightweight JPEG previews without modifying original product screenshots."""

from pathlib import Path
import subprocess
import tempfile


def main():
    images = Path(__file__).resolve().parent.parent / "assets" / "product"
    originals = sorted(images.glob("*.png"))
    if not originals:
        raise SystemExit(f"No product PNGs found in {images}")
    previews = images / "previews"
    previews.mkdir(exist_ok=True)
    total = 0
    with tempfile.TemporaryDirectory(dir=previews) as staging:
        for original in originals:
            target = Path(staging) / f"{original.stem}.jpg"
            subprocess.run(
                ["sips", "--resampleWidth", "1600", "-s", "format", "jpeg",
                 "-s", "formatOptions", "78", str(original), "--out", str(target)],
                check=True, capture_output=True, text=True,
            )
            size = target.stat().st_size
            target.replace(previews / target.name)
            total += size
            print(f"{target.name}: {size / 1024:.0f} KiB")
    original_size = sum(image.stat().st_size for image in originals)
    print(f"{len(originals)} previews: {total / 1024 / 1024:.2f} MiB "
          f"({100 * (1 - total / original_size):.1f}% smaller than PNG originals)")


if __name__ == "__main__":
    main()
