"""Check the one-shot sampling gate without starting any model or profiler."""
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

from run_screenshot import capture_stack, read_events, sample_gate


class SamplingTests(unittest.TestCase):
    def gate(self, events=None, **overrides):
        values = dict(events=events if events is not None else [
            {'stage': 'model-begin', 'pid': 42, 'uptime': 120}],
            trace=[{'uptime': 100, 'seconds': 0}],
            owned=[['42', '41', '42', 'T', '0', '1', '0:00', '/helper']],
            identities={42: 'start /helper'}, helper=Path('/helper'), launched=99,
            now=121, parent_deadline=160, stage_seconds=40)
        values.update(overrides)
        return sample_gate(**values)

    def test_waits_for_loader_then_uses_exact_owned_pid(self):
        self.assertIsNone(self.gate(events=[{'stage': 'swift-entry', 'pid': 42}]))
        result = self.gate()
        self.assertEqual(result['pid'], 42)
        self.assertEqual(result['remaining_before_cutoff_seconds'], 19)
        self.assertNotIn('skipped', result)

    def test_rejects_unowned_stale_and_identityless_stage(self):
        for overrides in [dict(owned=[]), dict(identities={}), dict(launched=121)]:
            with self.subTest(overrides=overrides):
                self.assertIn('skipped', self.gate(**overrides))

    def test_leaves_tool_and_cleanup_time_under_both_cutoffs(self):
        self.assertIn('skipped', self.gate(now=127))
        self.assertIn('skipped', self.gate(parent_deadline=134))
        self.assertNotIn('skipped', self.gate(now=126))
        self.assertIn('skipped', self.gate(trace=[]))

    def test_does_not_sample_after_loader_ended(self):
        self.assertIn('skipped', self.gate(events=[
            {'stage': 'model-begin', 'pid': 42, 'uptime': 120},
            {'stage': 'model-end', 'pid': 42, 'uptime': 120.5}]))

    def test_partial_stage_append_is_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'stages'
            path.write_text('{"stage":"model-begin"}\n{"pid":')
            self.assertEqual(read_events(path), [{'stage': 'model-begin'}])

    @patch('run_screenshot.subprocess.run')
    def test_identity_change_prevents_profiler_launch(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, stdout='different start')
        record = {'pid': 42}
        capture_stack(Path('/unused'), record, 'start /helper')
        self.assertIn('skipped', record)
        self.assertEqual(run.call_count, 1)

    @patch('run_screenshot.subprocess.run')
    def test_timeout_retains_partial_stdout_stderr_and_stack(self, run):
        def execute(command, **kwargs):
            if command[0] == 'ps':
                return subprocess.CompletedProcess(command, 0, stdout='start /helper')
            self.assertEqual(kwargs['timeout'], 12)
            self.assertEqual(command[2:4], ['1', '1'])
            kwargs['stdout'].write('partial stdout')
            kwargs['stderr'].write('partial stderr')
            Path(command[-1]).write_text('partial stack')
            raise subprocess.TimeoutExpired(command, 12)
        run.side_effect = execute
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            record = {'pid': 42, 'cutoff_monotonic': time.monotonic() + 20}
            capture_stack(root, record, 'start /helper')
            self.assertEqual(record['timeout_seconds'], 12)
            self.assertTrue(record['stack_file_exists'])
            self.assertEqual((root / 'sample.stdout.txt').read_text(), 'partial stdout')
            self.assertEqual((root / 'sample.stderr.txt').read_text(), 'partial stderr')
            self.assertEqual((root / 'current-stack.txt').read_text(), 'partial stack')


    @patch('run_screenshot.subprocess.run')
    def test_identity_check_cannot_consume_cleanup_reserve(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, stdout='start /helper')
        record = {'pid': 42, 'cutoff_monotonic': time.monotonic() + 13}
        capture_stack(Path('/unused'), record, 'start /helper')
        self.assertIn('skipped', record)
        self.assertEqual(run.call_count, 1)
