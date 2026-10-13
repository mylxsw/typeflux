"""Focused checks for the literal baseline ratchet; no Swift/AppKit dependency."""
import collections
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("ui_literal_guard", Path(__file__).parents[1] / "check_ui_literals.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class UILiteralGuardTests(unittest.TestCase):
    def test_rules_find_multiline_literals_and_ternaries(self):
        patterns = guard.patterns()
        samples = {
            "typeflux_literal_font": [".font(.system(size: 13))", ".font(\n .system(size: 13.5))",
                                     ".font(.system(size: compact ? 13.5 : 13))"],
            "typeflux_literal_radius": ["cornerRadius: 5", "cornerRadius:\n 8.5", "cornerRadius: small ? 7 : 8"],
            "typeflux_literal_nscolor": ["NSColor(calibratedWhite: 1, alpha: 1)", "NSColor(\n srgbRed: 1)"]
        }
        for rule, samples_for_rule in samples.items():
            for sample in samples_for_rule:
                self.assertIsNotNone(patterns[rule].search(sample), sample)

    def test_system_roles_and_tokens_are_allowed(self):
        samples = [".font(.body)", ".font(.system(.callout, design: .monospaced))",
                   "cornerRadius: TypefluxRadius.form.value(for: style)", "NSColor.labelColor"]
        for sample in samples:
            self.assertFalse(any(pattern.search(sample) for pattern in guard.patterns().values()), sample)

    def test_duplicates_and_new_locations_are_regressions(self):
        key = ("Sources/App.swift", "typeflux_literal_radius", "cornerRadius: 5")
        previous = collections.Counter({key: 1})
        self.assertEqual(guard.additions(collections.Counter({key: 2}), previous), {key: 1})
        other = ("Sources/New.swift", key[1], key[2])
        self.assertEqual(guard.additions(collections.Counter({key: 1, other: 1}), previous), {other: 1})
        self.assertFalse(guard.additions(collections.Counter(), previous))

    def test_decoding_preserves_per_signature_counts(self):
        entry = {"file": "Sources/App.swift", "rule": "typeflux_literal_radius", "match": "cornerRadius: 5", "count": 2}
        self.assertEqual(sum(guard.decode([entry]).values()), 2)
        self.assertEqual(sum(guard.decode([entry, entry]).values()), 4)
