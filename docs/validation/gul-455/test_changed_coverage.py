"""Regression checks for portable, fail-closed artifact recomputation."""
import unittest
from changed_coverage import EXPECTED, executable_lines, parse_lcov, repository_path


class ChangedCoverageTests(unittest.TestCase):
    def test_foreign_absolute_and_relative_paths_preserve_counts(self):
        source = next(iter(EXPECTED))
        raw = f'SF:/another/checkout/{source}\nDA:12,3\nend_of_record\nSF:{source}\nDA:12,0\nend_of_record\n'
        self.assertEqual(parse_lcov(raw), {source: {12: 3}})
        self.assertEqual(repository_path('/other/tree/' + source), source)

    def test_ambiguous_missing_and_traversal_paths_fail(self):
        for source in ['/tmp/unknown.swift', 'Sources/Typeflux/../other.swift',
                       '/Sources/Typeflux/repo/Sources/Typeflux/file.swift']:
            with self.subTest(source=source), self.assertRaises(ValueError):
                repository_path(source)

    def test_missing_file_or_changed_executable_records_fail(self):
        changed = {source: {12} for source in EXPECTED}
        complete = {source: {12: 1} if required else {} for source, required in EXPECTED.items()}
        self.assertEqual(len(executable_lines(changed, complete)), len(EXPECTED))
        for source, required in EXPECTED.items():
            missing = {key: dict(value) for key, value in complete.items()}
            del missing[source]
            if required:
                with self.subTest(source=source), self.assertRaises(ValueError):
                    executable_lines(changed, missing)
                missing[source] = {13: 1}
                with self.subTest(source=source), self.assertRaises(ValueError):
                    executable_lines(changed, missing)

    def test_orphan_or_invalid_executable_records_fail(self):
        for raw in ['DA:1,0', 'SF:Sources/Typeflux/file.swift\nDA:0,1',
                    'SF:Sources/Typeflux/file.swift\nDA:1,-1']:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                parse_lcov(raw)


if __name__ == '__main__':
    unittest.main()
