import importlib.util
import gzip
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("coverage", Path(__file__).with_name("changed_coverage.py"))
coverage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage)


class PortableCoverageTests(unittest.TestCase):
    def test_foreign_checkout_and_relative_paths(self):
        for path in ["/another/checkout/Sources/Typeflux/Ask/AskRunRoute.swift", "Sources/Typeflux/Ask/AskRunRoute.swift"]:
            self.assertEqual(coverage.repository_path(path), "Sources/Typeflux/Ask/AskRunRoute.swift")

    def test_reject_ambiguous_unrelated_and_traversal(self):
        for path in ["/other/AskRunRoute.swift", "/Sources/Typeflux/clone/Sources/Typeflux/file.swift", "/checkout/../Sources/Typeflux/file.swift", "Sources/Typeflux/../file.swift"]:
            with self.assertRaises(ValueError):
                coverage.repository_path(path)

    def test_go_module_path_rejection(self):
        self.assertEqual(coverage.go_repository_path("github.com/mylxsw/typeflux-api/internal/ask/store.go"), "internal/ask/store.go")
        for source in ["other/typeflux-api/internal/ask/store.go", "github.com/mylxsw/typeflux-api/internal/../ask/store.go"]:
            with self.assertRaises(ValueError):
                coverage.go_repository_path(source)

    def test_maximum_across_records_and_profiles(self):
        with tempfile.TemporaryDirectory() as directory:
            first, second = [Path(directory) / name for name in ("first", "second")]
            first.write_text("SF:/foreign/Sources/Typeflux/Ask/AskRunRoute.swift\nDA:12,3\nend_of_record\nSF:Sources/Typeflux/Ask/AskRunRoute.swift\nDA:12,1\nend_of_record\n")
            second.write_text("SF:/elsewhere/Sources/Typeflux/Ask/AskRunRoute.swift\nDA:12,0\nend_of_record\n")
            self.assertEqual(coverage.read_counts([first, second]), {("Sources/Typeflux/Ask/AskRunRoute.swift", 12): 3})
            first.write_text("mode: atomic\ngithub.com/mylxsw/typeflux-api/internal/ask/agent_binding.go:10.1,12.2 1 3\n")
            second.write_text("mode: atomic\ngithub.com/mylxsw/typeflux-api/internal/ask/agent_binding.go:10.1,12.2 1 0\n")
            self.assertEqual(coverage.read_counts([first, second]), {("internal/ask/agent_binding.go", n): 3 for n in range(10, 13)})
            compressed = Path(directory) / "profile.gz"
            compressed.write_bytes(gzip.compress(first.read_bytes()))
            self.assertEqual(coverage.read_counts([compressed]), coverage.read_counts([first]))


if __name__ == "__main__":
    unittest.main()
