import subprocess
import unittest
from observer import started_identity


class ProcessObservationTests(unittest.TestCase):
    def test_child_exit_between_snapshot_and_identity_is_benign(self):
        child = subprocess.Popen(['/usr/bin/true'])
        pid_from_snapshot = child.pid
        child.wait(timeout=5)
        self.assertIsNone(started_identity(pid_from_snapshot))

    def test_running_child_has_stable_identity(self):
        child = subprocess.Popen(['/bin/sleep', '1'])
        try:
            first = started_identity(child.pid)
            self.assertTrue(first)
            self.assertEqual(started_identity(child.pid), first)
        finally:
            child.wait(timeout=5)
        self.assertIsNone(started_identity(child.pid))


if __name__ == '__main__':
    unittest.main()
