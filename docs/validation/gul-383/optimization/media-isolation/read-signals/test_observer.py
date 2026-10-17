import ctypes
import os
from pathlib import Path
import struct
import signal
import subprocess
import tempfile
import unittest
import events

ROOT = Path(__file__).resolve().parent
LIBRARY = Path.cwd() / '.build/stage-budget/observe.dylib'


class EventFormatTests(unittest.TestCase):
    def test_empty_and_partial_commits(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'events'
            events.create(path, 2)
            self.assertEqual(events.read(path)['events'], [])
            with path.open('r+b') as output:
                output.write(struct.pack('<Q', 2))
                output.seek(32)
                event = events.Event(committed=1, kind=3, pid=42, sequence=7, uptime=2)
                output.write(bytes(event))
            data = events.read(path)
            self.assertEqual(data['incomplete'], 1)
            self.assertEqual(data['events'][0]['sequence'], 7)
            self.assertEqual(ctypes.sizeof(events.Event), 104)

    def test_rejects_mismatched_and_short_format(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'events'
            path.write_bytes(b'bad')
            with self.assertRaises(ValueError): events.read(path)
            path.write_bytes(struct.pack('<QQQQ', 0, 0, 0, 999))
            with self.assertRaises(ValueError): events.read(path)

    def test_does_not_overwrite_and_records_drops(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'events'
            events.create(path, 0)
            with self.assertRaises(FileExistsError): events.create(path)
            path.write_bytes(struct.pack('<QQQQ', 4, 4, 0, 104))
            self.assertEqual(events.read(path)['dropped'], 4)


class InterpositionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.TemporaryDirectory()
        cls.binary = Path(cls.folder.name) / 'fixture'
        subprocess.run(['clang', '-Wall', '-Wextra', '-Werror', str(ROOT / 'fixture.c'),
                        '-o', str(cls.binary)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls): cls.folder.cleanup()

    def run_fixture(self, capacity=1000, enabled=True, mode=0o600, utility=False):
        path = Path(self.folder.name) / ('buffer-' + str(len(list(Path(self.folder.name).iterdir()))))
        events.create(path, capacity); path.chmod(mode)
        fixture = Path(self.folder.name) / 'synthetic.gguf'
        fixture.write_bytes(b'GGUFprivate-test')
        env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(LIBRARY))
        env['GUL405_MEDIA_UTILITY'] = '1' if utility else '0'
        if enabled: env['GUL405_IO_BUFFER'] = str(path)
        else: env.pop('GUL405_IO_BUFFER', None)
        start = __import__('time').monotonic()
        result = subprocess.run([str(self.binary), str(fixture)], env=env, capture_output=True,
                                text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'forwarding-ok\n')
        self.assertNotIn(b'private-test', path.read_bytes())
        return events.read(path), start, __import__('time').monotonic()

    def test_real_reads_signals_identity_and_common_clock(self):
        data, start, end = self.run_fixture()
        self.assertEqual(data['dropped'], 0)
        rows = data['events']
        self.assertTrue(rows)
        self.assertTrue(all(start <= row['uptime'] <= end for row in rows))
        reads = [row for row in rows if row['kind'] == 3]
        self.assertEqual([(r['offset'], r['result']) for r in reads], [(0, 16), (16, 0)])
        self.assertTrue(all(r['uptime'] >= r['entered'] for r in reads))
        signals = [row for row in rows if row['kind'] == 5]
        self.assertEqual([r['count'] for r in signals], [signal.SIGSTOP, signal.SIGCONT, signal.SIGCONT])
        self.assertEqual([r['result'] for r in signals], [0, 0, -1])
        self.assertEqual(signals[-1]['error'], 3)
        self.assertGreater(signals[0]['start_seconds'], 0)
        self.assertEqual(signals[0]['start_seconds'], signals[1]['start_seconds'])
        before_resume = next(r for r in rows if r['kind'] == 4 and r['count'] == signal.SIGCONT)
        self.assertEqual(before_resume['status'], 4)  # Darwin SSTOP.

    def test_disabled_and_insecure_buffer_preserve_forwarding(self):
        self.assertEqual(self.run_fixture(enabled=False)[0]['events'], [])
        self.assertEqual(self.run_fixture(mode=0o644)[0]['events'], [])

    def test_full_buffer_preserves_forwarding(self):
        data, _, _ = self.run_fixture(capacity=1)
        self.assertGreater(data['dropped'], 0)
        self.assertEqual(len(data['events']), 1)

    def test_qos_comparison_is_opt_in_and_keeps_utility(self):
        baseline = [r for r in self.run_fixture()[0]['events'] if r['kind'] == 6]
        changed = [r for r in self.run_fixture(utility=True)[0]['events'] if r['kind'] == 6]
        self.assertEqual([r['count'] for r in baseline], [9, 17])
        self.assertEqual([r['size'] for r in baseline], [9, 17])
        self.assertEqual([r['size'] for r in changed], [17, 17])
        self.assertTrue(all(r['result'] == 0 for r in baseline + changed))


if __name__ == '__main__': unittest.main()
