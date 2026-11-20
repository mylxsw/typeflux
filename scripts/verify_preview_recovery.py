#!/usr/bin/env python3
"""Exercise the packaged macOS app across an upgrade and abrupt host exits."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import struct
import subprocess
import tempfile
import time
import uuid


SERVICES = (
    "mediaExtraction", "mediaPreviews", "clipboardThumbnails", "textRecognition",
    "clipboardOCR", "clipboardMetadata", "nativeSystem", "mediaPlayback",
)


def services_available(directory):
    for service in SERVICES:
        path = directory / f"{service}.json"
        if not path.exists():
            return False
        record = json.loads(path.read_bytes())
        if record["version"] != 2 or record["quarantined"] or not record.get("reusable"):
            return False
    return True


def has_visible_detail(pixels, width, height):
    if len(pixels) != width * height * 4 or not any(pixels[3::4]):
        return False
    return pixels != pixels[:4] * (width * height)


def preview_status(cache, image_path):
    icons = cache / "LauncherIcons"
    thumbs = cache / "clipboard-thumbnails-v1"
    has_icon = any(has_visible_detail(path.read_bytes(), 112, 112) for path in icons.glob("*.rgba"))
    prefix = hashlib.sha256(str(image_path).encode()).hexdigest()
    for path in thumbs.glob(f"{prefix}-*.rgba"):
        data = path.read_bytes()
        if len(data) < 12 or data[:4] != b"TFC1":
            continue
        width, height = struct.unpack(">II", data[4:12])
        if 0 < width <= 480 and 0 < height <= 480 and has_visible_detail(data[12:], width, height):
            return has_icon, True
    return has_icon, False


def seed_image(database, image, target):
    content = image.read_bytes()
    target.parent.mkdir(exist_ok=True)
    target.write_bytes(content)
    width, height = struct.unpack(">II", content[16:24])
    with sqlite3.connect(database) as conn:
        conn.execute(
            """INSERT INTO clipboard_items
               (id, payload, date, image_path, image_width, image_height, byte_size, content_hash)
               VALUES (?, 'image', ?, ?, ?, ?, ?, ?)""",
            (str(uuid.uuid4()).upper(), time.time(), str(target), width, height, len(content),
             hashlib.sha256(content).hexdigest()),
        )


def verify(app):
    executable = (app / "Contents/MacOS/Typeflux").resolve(strict=True)
    image = (Path(__file__).resolve().parents[1] / "Sources/Typeflux/Resources/LauncherFeatureIcons"
             / "light/launcher-feature-light-chat.png")
    with tempfile.TemporaryDirectory(prefix="typeflux-release-recovery-") as name:
        home = Path(name).resolve()
        data = home / ".typeflux/data"
        cache = home / ".typeflux/cache"
        health = data / "ModuleHealth"
        health.mkdir(parents=True)
        for service in SERVICES:
            (health / f"{service}.json").write_text('{"version":1,"attempts":4,"quarantined":true}')
        database = data / "clipboard.sqlite"
        image_path = data / "clipboard-images" / "fixture.png"
        env = {key: os.environ[key] for key in ("PATH", "TMPDIR", "LANG") if key in os.environ}
        env["CFFIXED_USER_HOME"] = str(home)
        for launch in range(1, 7):
            for folder in [cache / "LauncherIcons", cache / "clipboard-thumbnails-v1"]:
                if folder.exists():
                    shutil.rmtree(folder)
            command = ["/usr/bin/sandbox-exec", "-f", Path(__file__).with_name("preview_test.sb"), executable]
            with subprocess.Popen(command, env=env, start_new_session=True,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as proc:
                try:
                    deadline = time.monotonic() + 60
                    while time.monotonic() < deadline:
                        if proc.poll() is not None:
                            raise RuntimeError(f"Launch {launch}: app exited with {proc.returncode}")
                        if services_available(health):
                            if launch == 1 and database.exists():
                                with sqlite3.connect(database) as conn:
                                    if conn.execute("SELECT 1 FROM sqlite_master WHERE name='clipboard_items'").fetchone():
                                        break
                            elif launch > 1 and all(preview_status(cache, image_path)):
                                break
                        time.sleep(0.2)
                    else:
                        has_icon, has_thumbnail = preview_status(cache, image_path)
                        raise RuntimeError(
                            f"Launch {launch}: services ready={services_available(health)}, "
                            f"app icon present={has_icon}, fixture thumbnail present={has_thumbnail}"
                        )
                finally:
                    # Exercise the failure path without allowing graceful quit to reset the counters.
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    proc.wait()
            if launch == 1:
                seed_image(database, image, image_path)
            print(f"Launch {launch}: " + ("legacy services recovered" if launch == 1
                  else "fresh app icons and clipboard thumbnail verified"), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    verify(parser.parse_args().app)
