import signal
import unittest
from analyze import summarize


class CorrelationTests(unittest.TestCase):
    def event(self, kind, at, **values):
        row = dict(kind=kind, uptime=at, entered=at, pid=1, target=2, start_seconds=10,
                   start_microseconds=20, result=0, count=0, size=1, offset=0, sequence=0, status=2)
        row.update(values); return row

    def test_read_overlap_does_not_call_residual_cpu_time(self):
        rows = [self.event(5, 2, count=signal.SIGSTOP, status=4),
                self.event(5, 6.1, count=signal.SIGCONT, entered=6),
                self.event(3, 8, entered=1, pid=2, result=8, sequence=5)]
        value = summarize(rows)['2']
        self.assertEqual(value['stop_pairs'], 1)
        read = value['slowest_recorded_reads'][0]
        self.assertEqual(read['commanded_stop_overlap_seconds'], 4)
        self.assertEqual(read['wall_outside_commanded_stops_seconds'], 3)

    def test_pid_reuse_or_failed_signal_cannot_claim_pause_duration(self):
        rows = [self.event(5, 2, count=signal.SIGSTOP),
                self.event(5, 6, count=signal.SIGCONT, start_microseconds=21)]
        self.assertFalse(summarize(rows)['2']['identity_consistent'])
        self.assertEqual(summarize(rows)['2']['stop_pairs'], 0)
        rows[1].update(start_microseconds=20, result=-1)
        self.assertEqual(summarize(rows)['2']['stop_pairs'], 0)
        self.assertEqual(summarize(rows)['2']['unmatched_final_stop'], 2)


if __name__ == '__main__': unittest.main()
