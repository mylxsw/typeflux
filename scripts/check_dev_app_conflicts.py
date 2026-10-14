#!/usr/bin/env python3
"""Refuse to launch a dev build alongside another Typeflux installation."""

import os
from pathlib import Path
import plistlib
import subprocess
import sys


BUNDLE_ID = "ai.gulu.app.typeflux"
EXECUTABLE_SUFFIX = "/Contents/MacOS/Typeflux"


def find_conflicts(processes: str, dev_app: Path) -> list[tuple[int, Path, str]]:
    conflicts = []
    desired = os.path.realpath(dev_app)
    for line in processes.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) != 2 or not fields[0].isdigit():
            continue
        pid, executable = fields
        if not executable.endswith(EXECUTABLE_SUFFIX):
            continue
        app = Path(executable[: -len(EXECUTABLE_SUFFIX)])
        if os.path.realpath(app) == desired:
            continue
        try:
            with (app / "Contents/Info.plist").open("rb") as info_file:
                info = plistlib.load(info_file)
        except (OSError, ValueError, plistlib.InvalidFileException):
            # A running app may have been moved or removed after launch.
            info = None
        if info is not None and info.get("CFBundleIdentifier") != BUNDLE_ID:
            continue
        if info is None and app.name != "Typeflux.app":
            continue
        version = str(info.get("CFBundleShortVersionString", "unknown")) if info else "unknown"
        conflicts.append((int(pid), app, version))
    return conflicts


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: check_dev_app_conflicts.py DEV_APP_PATH", file=sys.stderr)
        return 2
    processes = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
    conflicts = find_conflicts(processes, Path(sys.argv[1]))
    if not conflicts:
        return 0
    print("Another Typeflux app is running alongside the dev build:", file=sys.stderr)
    for pid, app, version in conflicts:
        print(f"  PID {pid}: {app} (version {version})", file=sys.stderr)
    print("Quit that app before launching Typeflux Dev to avoid using stale code.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
