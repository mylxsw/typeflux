"""Check detection of stale app instances without starting macOS apps."""

import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "check_dev_app_conflicts.py"
SPEC = importlib.util.spec_from_file_location("check_dev_app_conflicts", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DevAppConflictsTests(unittest.TestCase):
    def test_detects_old_install_but_ignores_current_dev_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dev = root / "Typeflux Dev.app"
            old = root / "Typeflux.app"
            info = old / "Contents/Info.plist"
            info.parent.mkdir(parents=True)
            with info.open("wb") as output:
                plistlib.dump({"CFBundleIdentifier": "ai.gulu.app.typeflux",
                               "CFBundleShortVersionString": "0.3.0"}, output)
            processes = (f"123 {dev}/Contents/MacOS/Typeflux\n"
                         f"456 {old}/Contents/MacOS/Typeflux\n")
            self.assertEqual(MODULE.find_conflicts(processes, dev), [(456, old, "0.3.0")])

    def test_detects_removed_old_install_and_ignores_unrelated_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            old = root / "Typeflux.app"
            other = root / "Another.app"
            processes = (f"456 {old}/Contents/MacOS/Typeflux\n"
                         f"789 {other}/Contents/MacOS/Typeflux\n")
            self.assertEqual(MODULE.find_conflicts(processes, root / "Typeflux Dev.app"),
                             [(456, old, "unknown")])

    def test_ignores_app_with_different_bundle_identifier(self):
        with tempfile.TemporaryDirectory() as temporary:
            old_name = Path(temporary) / "Typeflux.app"
            info = old_name / "Contents/Info.plist"
            info.parent.mkdir(parents=True)
            with info.open("wb") as output:
                plistlib.dump({"CFBundleIdentifier": "com.example.other"}, output)
            processes = f"456 {old_name}/Contents/MacOS/Typeflux\n"
            self.assertEqual(MODULE.find_conflicts(processes, Path(temporary) / "Dev.app"), [])


if __name__ == "__main__":
    unittest.main()
