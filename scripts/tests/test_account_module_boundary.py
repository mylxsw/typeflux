import contextlib
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_account_module_boundary as boundary
from check_account_module_boundary import declarations, violations


class AccountBoundaryTests(unittest.TestCase):
    def test_new_project_type_is_reported_in_code_and_interpolation(self):
        for source in ('let value: AskOnly?', 'Text("Value: \\(AskOnly.value)")'):
            self.assertEqual(violations(source, {"AskOnly"}), ["AskOnly"])

    def test_comments_and_literal_text_are_not_dependencies(self):
        self.assertEqual(violations('/* AskOnly */ "AskOnly" // AskOnly', {"AskOnly"}), [])

    def test_shim_member_contract(self):
        for allowed in ("FeatureProcess.enabled", "FeatureAuth.refresh()", "FeatureRPC.Failure.unavailable"):
            self.assertEqual(violations(allowed, set()), [])
        for unknown in ("FeatureProcess.kill", "FeatureRPC.Failure.timeout", "FeatureAuth"):
            self.assertEqual(violations(unknown, set()), [unknown])

    def test_project_types_exclude_nested_sdk_name_collisions(self):
        self.assertEqual(declarations("@MainActor final class ProductOnly {\n    enum Result {}\n}"), {"ProductOnly"})

    def test_worktree_checks_untracked_files_module_imports_and_missing_manifest_entries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            auth = root / boundary.AUTH
            auth.mkdir(parents=True)
            (root / "scripts").mkdir()
            source = auth / "Account.swift"
            source.write_text("struct Account {}")
            (auth.parent / "Legacy.swift").write_text("struct Legacy {}")
            manifest = root / "scripts/account_module_files.txt"
            manifest.write_text(str(source.relative_to(root)) + "\n")
            git = ["git", "-C", directory]
            subprocess.run([*git, "init", "-q"], check=True)
            subprocess.run([*git, "add", "."], check=True)
            subprocess.run([*git, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                            "commit", "-qm", "Baseline"], check=True)
            with patch.object(boundary, "ROOT", root), patch.object(boundary, "BASELINE", "HEAD"):
                source.write_text("struct Account { let value: Legacy }")
                self.assertFalse(boundary.main())
                (auth.parent / "New.swift").write_text("@MainActor final class ProductOnly {}")
                (root / "Sources/NewRuntime").mkdir()
                (auth / "Missing.swift").write_text("struct Missing {}")
                source.write_text("import NewRuntime\nstruct Account { let value: ProductOnly }")
                diagnostics = io.StringIO()
                with contextlib.redirect_stderr(diagnostics):
                    self.assertTrue(boundary.main())
                for message in ("Account.swift: NewRuntime", "Account.swift: ProductOnly",
                                "Missing.swift: missing from account manifest"):
                    self.assertIn(message, diagnostics.getvalue())
