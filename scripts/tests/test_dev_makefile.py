"""Verify Mac LAN targets without building or launching the real application."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class DevelopmentMakefileTests(unittest.TestCase):
    def test_focused_targets_pass_scope_through_environment_without_shell_interpolation(self):
        with tempfile.TemporaryDirectory(prefix="typeflux-make-") as temporary:
            workspace = Path(temporary)
            shutil.copyfile(ROOT / "Makefile", workspace / "Makefile")
            script = workspace / "scripts/test_groups.py"
            script.parent.mkdir()
            script.write_text(
                'import json, os, sys\n'
                'print(json.dumps({"args": sys.argv[1:], "filter": os.getenv("FILTER"), '
                '"suite": os.getenv("SUITE"), "reason": os.getenv("REASON")}))\n'
            )
            for target, flags in (("test", []), ("test-plan", ["--plan"]), ("test-full", ["--full"])):
                environment = dict(os.environ, FILTER="Suite/test[ab]; `touch injected`", SUITE="A B", REASON="requested")
                output = subprocess.check_output(["make", "--no-print-directory", target],
                                                 cwd=workspace, env=environment, text=True)
                self.assertEqual(json.loads(output.splitlines()[-1]), {
                    "args": ["--from-env", *flags], "filter": environment["FILTER"],
                    "suite": "A B", "reason": "requested",
                })
            self.assertFalse((workspace / "injected").exists())

    def test_real_screen_capture_target_explicitly_enables_only_its_swift_command(self):
        with tempfile.TemporaryDirectory(prefix="typeflux-make-") as temporary:
            workspace = Path(temporary)
            shutil.copyfile(ROOT / "Makefile", workspace / "Makefile")
            swift = workspace / "swift"
            swift.write_text(
                '#!/usr/bin/env python3\n'
                'import json, os, sys\n'
                'print(json.dumps({"args": sys.argv[1:], '
                '"capture": os.getenv("TYPEFLUX_REAL_SCREEN_CAPTURE_TESTS")}))\n'
            )
            swift.chmod(0o755)
            environment = dict(os.environ, PATH=f"{workspace}{os.pathsep}{os.environ['PATH']}",
                               TYPEFLUX_REAL_SCREEN_CAPTURE_TESTS="0")
            output = subprocess.check_output(
                ["make", "--no-print-directory", "test-screen-capture"],
                cwd=workspace, env=environment, text=True,
            )
            self.assertEqual(json.loads(output.splitlines()[-1]), {
                "args": ["test", "--no-parallel", "--filter", "ScreenshotCaptureWindowPolicyTests"],
                "capture": "1",
            })
            self.assertEqual(environment["TYPEFLUX_REAL_SCREEN_CAPTURE_TESTS"], "0")

    def test_ios_platform_selects_native_ios_launcher_and_forwards_device(self):
        with tempfile.TemporaryDirectory(prefix="typeflux-make-") as temporary:
            workspace = Path(temporary)
            shutil.copyfile(ROOT / "Makefile", workspace / "Makefile")
            script = workspace / "scripts" / "ios.py"
            script.parent.mkdir()
            script.write_text(
                'import json, os, sys\n'
                'print(json.dumps({"args": sys.argv[1:], "api": os.getenv("TYPEFLUX_API_URL"), '
                '"target": os.getenv("TYPEFLUX_IOS_TARGET"), "http": os.getenv("TYPEFLUX_ALLOW_INSECURE_HTTP")}))\n'
            )
            for target, host in (("dev-macbook", "mac-pro.local"), ("dev-macmini", "mac-mini.local")):
                with self.subTest(target=target):
                    output = subprocess.check_output(
                        ["make", "--no-print-directory", target, "PLATFORM=ios", "DEVICE=TEST-UDID"],
                        cwd=workspace, text=True,
                    )
                    self.assertEqual(json.loads(output.splitlines()[-1]), {
                        "args": ["start"], "api": f"http://{host}:8080", "target": "TEST-UDID", "http": "YES",
                    })

    def test_invalid_platform_cannot_silently_launch_macos(self):
        result = subprocess.run(["make", "dev-macbook", "PLATFORM=android"], cwd=ROOT, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PLATFORM must be macos or ios", result.stderr)

    def test_mac_targets_override_inherited_api_lists_and_preserve_variant(self):
        with tempfile.TemporaryDirectory(prefix="typeflux-make-") as temporary:
            workspace = Path(temporary)
            shutil.copyfile(ROOT / "Makefile", workspace / "Makefile")
            script = workspace / "scripts" / "run_dev_attached.sh"
            script.parent.mkdir()
            script.write_text(
                '#!/usr/bin/env python3\n'
                'import json, os\n'
                'print(json.dumps({key: os.environ.get(key) for key in '
                '("TYPEFLUX_API_URL", "TYPEFLUX_API_URLS", "TYPEFLUX_DEV_VARIANT")}))\n'
            )
            script.chmod(0o755)
            for target, host in (("dev-macbook", "mac-pro.local"), ("dev-macmini", "mac-mini.local")):
                with self.subTest(target=target):
                    environment = dict(os.environ, TYPEFLUX_API_URL="https://old.example",
                                       TYPEFLUX_API_URLS="https://old.example,https://backup.example",
                                       TYPEFLUX_DEV_VARIANT="full")
                    output = subprocess.check_output(
                        ["make", "--no-print-directory", target], cwd=workspace,
                        env=environment, text=True,
                    )
                    configuration = json.loads(output.splitlines()[-1])
                    self.assertEqual(configuration["TYPEFLUX_API_URL"], f"http://{host}:8080")
                    self.assertEqual(configuration["TYPEFLUX_API_URLS"], f"http://{host}:8080")
                    self.assertEqual(configuration["TYPEFLUX_DEV_VARIANT"], "full")
