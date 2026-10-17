"""Synthetic bundle structure only. Fake binaries are hashed, never executed."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("stage4_preflight", ROOT / "scripts/stage4_preflight.py")
preflight = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preflight)
COMMIT = "a" * 40


class Stage4PreflightTests(unittest.TestCase):
    def setUp(self):
        fixtures = ROOT / ".build/stage4-preflight-fixtures"
        fixtures.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=fixtures)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "Typeflux.app"
        self.info = {"CFBundleIdentifier": "ai.gulu.app.typeflux", "CFBundleExecutable": "Typeflux",
                     "NSMicrophoneUsageDescription": "Private fixture"}
        self.file("Contents/Info.plist", plistlib.dumps(self.info))
        self.binaries = ["Contents/MacOS/Typeflux", "Contents/Helpers/TypefluxInferenceHelper",
                         "Contents/Helpers/TypefluxMediaHelper",
                         "Contents/Resources/LocalRuntimes/SemanticSearch/TypefluxSemanticHelper"]
        for relative in self.binaries:
            self.file(relative, b"not executable native code", 0o700)
        self.resource = "Contents/Helpers/swift-transformers_Hub.bundle/tokenizer.json"
        self.file(self.resource, b"{}")

    def file(self, relative, data, mode=0o600):
        path = self.app / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(mode)
        return path

    def inspect(self, architecture="arm64"):
        return preflight.inspect_bundle(self.app, architecture, COMMIT)

    def test_valid_bundle_records_hashes_but_never_accepts_manual_gates(self):
        before = {str(p.relative_to(self.app)): p.read_bytes() for p in self.app.rglob("*") if p.is_file()}
        report = self.inspect()
        self.assertEqual(report["structure_status"], "pass")
        self.assertFalse(report["stage4_accepted"])
        self.assertEqual(set(report["manual_gates"].values()), {"not_verified"})
        self.assertEqual(len(report["manual_gates"]), 7)
        self.assertEqual(report["source_commit_claim"], COMMIT)
        for relative, item in report["files"].items():
            self.assertEqual(item["sha256"], hashlib.sha256(before[relative]).hexdigest())
        self.assertEqual(before, {str(p.relative_to(self.app)): p.read_bytes()
                                  for p in self.app.rglob("*") if p.is_file()})
        self.assertNotIn(str(self.root), json.dumps(report))

    def test_intel_omits_semantic_but_arm_and_universal_require_it(self):
        (self.app / self.binaries[-1]).unlink()
        self.assertEqual(self.inspect("x86_64")["structure_status"], "pass")
        for architecture in ["arm64", "universal"]:
            with self.subTest(architecture=architecture), self.assertRaises(OSError):
                self.inspect(architecture)

    def test_missing_nonexecutable_and_wrong_member_type_are_refused(self):
        path = self.app / self.binaries[1]
        path.chmod(0o600)
        with self.assertRaisesRegex(ValueError, "not executable"):
            self.inspect()
        path.unlink(); path.mkdir()
        with self.assertRaisesRegex(ValueError, "type"):
            self.inspect()
        path.rmdir()
        with self.assertRaises(FileNotFoundError):
            self.inspect()

    def test_original_identity_executable_and_purpose_are_required(self):
        for key, value in [("CFBundleIdentifier", "foreign.app"), ("CFBundleExecutable", "../foreign"),
                           ("NSMicrophoneUsageDescription", " "), ("NSMicrophoneUsageDescription", 1)]:
            info = dict(self.info, **{key: value})
            self.file("Contents/Info.plist", plistlib.dumps(info))
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                self.inspect()

    def test_symlink_root_parent_and_resources_cannot_read_outside_bundle(self):
        alias = self.root / "alias.app"; alias.symlink_to(self.app)
        with self.assertRaises(ValueError):
            preflight.inspect_bundle(alias, "arm64", COMMIT)
        path = self.app / self.resource
        outside = self.root / "outside"; outside.write_bytes(b"private fixture")
        path.unlink(); path.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "Symlink"):
            self.inspect()
        path.unlink(); path.parent.rmdir(); path.parent.symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, "Symlink"):
            self.inspect()

    def test_empty_and_oversized_members_and_resource_bundle_are_refused(self):
        path = self.app / self.resource
        path.write_bytes(b"")
        with self.assertRaisesRegex(ValueError, "Empty"):
            self.inspect()
        path.unlink()
        with self.assertRaisesRegex(ValueError, "empty"):
            self.inspect()
        data = self.root / "large"; data.write_bytes(b"abc")
        with self.assertRaises(ValueError):
            preflight.fingerprint(data, maximum_bytes=2)

    def test_commit_and_architecture_must_be_explicit(self):
        for commit in ["main", "1234567", "z" * 40]:
            with self.assertRaises(ValueError):
                preflight.inspect_bundle(self.app, "arm64", commit)
        with self.assertRaises(ValueError):
            self.inspect("native")

    def test_changed_file_is_refused_instead_of_receiving_a_stable_receipt(self):
        path = self.root / "changing"; path.write_bytes(b"abc")
        before = path.stat()
        fake_after = type("Changed", (), {"st_dev": before.st_dev, "st_ino": before.st_ino,
                                          "st_size": 4, "st_mtime_ns": before.st_mtime_ns})()
        with patch.object(preflight.os, "fstat", return_value=fake_after), self.assertRaisesRegex(ValueError, "changed"):
            preflight.fingerprint(path)

    def run_cli(self):
        output = io.StringIO()
        with patch("sys.argv", ["stage4_preflight.py", "--app", str(self.app), "--architecture", "arm64",
                                "--source-commit", COMMIT]), contextlib.redirect_stdout(output):
            status = preflight.main()
        return status, json.loads(output.getvalue())

    def test_cli_returns_structural_success_and_structured_failure_without_launching(self):
        status, report = self.run_cli()
        self.assertEqual(status, 0); self.assertFalse(report["stage4_accepted"])
        (self.app / self.binaries[0]).unlink()
        status, report = self.run_cli()
        self.assertEqual(status, 1); self.assertEqual(report["structure_status"], "fail")
        self.assertNotIn(str(self.root), json.dumps(report))

    def test_invalid_plists_fail_with_no_manual_gate_pass(self):
        for data in [b"not a plist", b'<?xml version="1.0"?><plist><dict>', plistlib.dumps(["wrong type"])]:
            self.file("Contents/Info.plist", data)
            status, report = self.run_cli()
            self.assertEqual(status, 1); self.assertFalse(report["stage4_accepted"])
            self.assertEqual(set(report["manual_gates"].values()), {"not_verified"})


if __name__ == "__main__":
    unittest.main()
