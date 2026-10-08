"""Exercise the importer without network access or modifying committed assets."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("sync_model_icons", Path(__file__).parents[1] / "sync_model_icons.py")
SYNC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNC)


class ModelIconSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "src").mkdir()
        rows = [dict(id="Claude", title="Claude", group="model", param=dict(hasColor=True)),
                dict(id="OpenAI", title="OpenAI", group="provider", param=dict(hasColor=False)),
                dict(id="Kimi", title="Kimi", group="provider", param=dict(hasColor=True)),
                dict(id="Excluded", title="Excluded", group="application", param=dict(hasColor=True))]
        (self.root / "src/toc.json").write_text(json.dumps(rows))
        (self.root / "LICENSE").write_text("MIT License")
        for theme in ("light", "dark"):
            directory = self.root / "packages/static-png" / theme
            directory.mkdir(parents=True)
            for name in ("claude-color.png", "openai.png", "kimi.png"):
                (directory / name).write_bytes(b"\x89PNG\r\n\x1a\nfixture")

    def collect(self):
        with patch.object(SYNC.subprocess, "check_output", side_effect=[SYNC.PINNED_REVISION, ""]):
            return SYNC.collect(self.root, SYNC.PINNED_REVISION)

    def test_collects_models_and_supplemental_providers_with_hashes(self):
        files = self.collect()
        self.assertEqual(len(files), 8)
        manifest = json.loads(files["catalog.json"])
        self.assertEqual([x["key"] for x in manifest["icons"]], ["claude", "kimi", "openai"])
        self.assertFalse(manifest["icons"][0]["monochrome"])
        self.assertTrue(manifest["icons"][1]["monochrome"])
        self.assertEqual(len(manifest["icons"][0]["sha256"]["dark"]), 64)

    def test_rejects_wrong_revision_or_dirty_checkout(self):
        for values in [["wrong"], [SYNC.PINNED_REVISION, " M src/toc.json"]]:
            with patch.object(SYNC.subprocess, "check_output", side_effect=values), self.assertRaises(ValueError):
                SYNC.collect(self.root, SYNC.PINNED_REVISION)

    def test_rejects_missing_and_invalid_assets_before_writing(self):
        path = self.root / "packages/static-png/light/claude-color.png"
        path.write_bytes(b"not a png")
        with self.assertRaises(ValueError):
            self.collect()
        path.unlink()
        with self.assertRaises(FileNotFoundError):
            self.collect()

    def test_sync_check_and_retired_asset_cleanup_preserve_rules(self):
        files = self.collect()
        destination = self.root / "output"
        destination.mkdir()
        (destination / "retired-light.png").write_bytes(b"old")
        (destination / "rules.json").write_text("{}")
        args = ["sync_model_icons.py", "--source", str(self.root)]
        with patch.object(SYNC, "DESTINATION", destination), patch.object(SYNC, "collect", return_value=files), \
                contextlib.redirect_stdout(io.StringIO()):
            with patch("sys.argv", args + ["--check"]), self.assertRaises(SystemExit):
                SYNC.main()
            self.assertTrue((destination / "retired-light.png").exists())
            with patch("sys.argv", args):
                SYNC.main()
            self.assertFalse((destination / "retired-light.png").exists())
            self.assertEqual((destination / "rules.json").read_text(), "{}")
            with patch("sys.argv", args + ["--check"]):
                SYNC.main()


class ResourceBundlePackagingTests(unittest.TestCase):
    def test_packaging_copies_shared_resources_and_rejects_incomplete_builds(self):
        script = Path(__file__).parents[1] / "copy_resource_bundles.sh"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "build", root / "App.app/Contents/Resources"
            source.mkdir()
            destination.mkdir(parents=True)
            names = ["Typeflux_Typeflux.bundle", "TypefluxChat_TypefluxChat.bundle"]
            (source / names[0]).mkdir()
            (destination / "keep.txt").write_text("unchanged")
            result = subprocess.run(["bash", str(script), str(source), str(destination)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"Missing resource bundle", result.stderr)
            self.assertEqual((destination / "keep.txt").read_text(), "unchanged")
            (source / names[1]).mkdir()
            for name in names:
                (source / name / "asset.png").write_bytes(b"fixture")
                (destination / name).mkdir()
                (destination / name / "obsolete.png").write_bytes(b"old")
            subprocess.run(["bash", str(script), str(source), str(destination)], check=True)
            for name in names:
                self.assertEqual((destination / name / "asset.png").read_bytes(), b"fixture")
                self.assertFalse((destination / name / "obsolete.png").exists())
            for name in ["build_release.sh", "run_dev_app.sh", "run_dev_attached.sh"]:
                self.assertIn("copy_resource_bundles.sh", (script.parent / name).read_text())


if __name__ == "__main__":
    unittest.main()
