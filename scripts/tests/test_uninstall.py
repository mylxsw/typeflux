"""Exercise the macOS uninstaller in disposable directories with fake system services."""

import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "uninstall.sh"
DOMAIN = "ai.gulu.app.typeflux"


class UninstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.desktop = self.home / "Desktop"
        self.desktop.mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.system_apps = self.root / "Applications"
        self.script = self.desktop / "Clean Typeflux.command"
        source = SCRIPT.read_text()
        # Isolate absolute macOS paths too. Never signal an app, unregister a
        # real bundle, or touch privacy grants, defaults or the user's Keychain.
        source = source.replace("in /Applications ", f'in "{self.system_apps}" ')
        source = source.replace("/tmp/typeflux-ipc-", f'"{self.root}"/typeflux-ipc-')
        source = source.replace("lsregister=/System/", "# lsregister=/System/", 1)
        self.script.write_text("lsregister=lsregister\n" + source)
        self.stub("ps", "exit 0")
        self.stub("lsregister", "exit 0")
        self.stub("defaults", "exit 1")
        self.stub("tccutil", 'echo "$*" >> "$HOME/tcc"')
        self.stub("security", 'echo "$*" >> "$HOME/security"; exit 44')
        self.stub("getconf", 'echo "$HOME/temp"')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def clean(self, *args, **env):
        environment = dict(HOME=str(self.home), PATH=f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin", **env)
        return subprocess.run(["/bin/bash", str(self.script), *args], env=environment,
                              text=True, capture_output=True, timeout=10)

    def make_app(self, folder, bundle_id):
        contents = folder / "Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": bundle_id}))

    def test_desktop_cleanup_is_targeted_and_repeatable(self):
        data = self.home / ".typeflux"
        workspace = self.home / "Documents/Typeflux/Workspaces"
        workspace.parent.mkdir(parents=True)
        export = workspace.parent / "user-export.txt"
        export.touch()
        data.mkdir()
        workspace.symlink_to(data)
        other_build = self.home / ".build"
        other_build.mkdir()
        app = self.system_apps / "Typeflux.app"
        self.make_app(app, DOMAIN)
        cache = self.home / "Library/HTTPStorages" / (DOMAIN + ".chat-window")
        cache.mkdir(parents=True)
        preview = self.clean("--dry-run")
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertTrue(app.exists() and data.exists() and workspace.is_symlink() and cache.exists())
        self.assertFalse((self.home / "security").exists() or (self.home / "tcc").exists())
        for _ in range(2):
            result = self.clean("--yes")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(data.exists() or workspace.is_symlink() or app.exists() or cache.exists())
            self.assertTrue(export.is_file() and other_build.is_dir())
        self.assertEqual(set((self.home / "tcc").read_text().splitlines()),
                         {f"reset All {domain}" for domain in (DOMAIN, DOMAIN + ".chat-window", "com.typeflux")})
        services = (self.home / "security").read_text()
        for service in ("com.typeflux.ask.search", "com.typeflux.ask.image-generation", "com.typeflux.mcp.oauth",
                        DOMAIN + ".google-cloud-speech", DOMAIN + ".auth.v1", DOMAIN + ".auth.v2"):
            self.assertIn("delete-generic-password -s " + service + "\n", services)

    def test_keep_build_preserves_products_and_source_project(self):
        project = self.root / "checkout"
        source = project / "Sources/Typeflux/App/TypefluxDataDirectories.swift"
        source.parent.mkdir(parents=True)
        source.touch()
        (project / "Package.swift").touch()
        (project / "scripts").mkdir()
        installed = project / "scripts/uninstall.sh"
        self.script.rename(installed)
        self.script = installed
        app = project / ".build/release/Typeflux.app"
        self.make_app(app, DOMAIN)
        xcode = project / "TypefluxApp.xcodeproj"
        xcode.mkdir()
        result = self.clean("--yes", "--keep-build")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(app.is_dir())
        result = self.clean("--yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(app.exists())
        self.assertTrue(xcode.is_dir())

    def test_other_apps_and_linked_documents_survive(self):
        app = self.system_apps / "Typeflux.app"
        self.make_app(app, "example.other")
        documents = self.home / "Documents/Typeflux"
        documents.parent.mkdir()
        other = self.root / "other"
        (other / "Workspaces").mkdir(parents=True)
        documents.symlink_to(other)
        result = self.clean("--yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(app.is_dir() and (other / "Workspaces").is_dir())
        self.assertIn("Unrecognized application", result.stderr)

    def test_keychain_failures_are_not_item_absence(self):
        self.stub("security", "exit 36")
        result = self.clean("--yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("returned 36", result.stderr)
        self.assertNotIn("Typeflux cleanup complete.", result.stdout)


if __name__ == "__main__":
    unittest.main()
