#!/usr/bin/env python3
"""Focused evidence-contract checks; no inference request or product test rerun."""
import json
from pathlib import Path
import re
import unittest

from analyze import analyze, cpu_seconds, rows

ROOT = Path(__file__).resolve().parent


class EvidenceTests(unittest.TestCase):
    def test_observed_budget_endpoints_and_no_vector(self):
        result = analyze(ROOT / 'screenshot-once')
        self.assertEqual(result['media_requests'], 1)
        self.assertEqual(result['media_responses'], 0)
        self.assertFalse(result['complete'])
        request, = result['requests']
        self.assertTrue(request['actual_budget_present'])
        self.assertTrue(request['enabled'])
        self.assertEqual(request['accounted_yields'], 283)
        self.assertAlmostEqual(request['accounted_budget_yield_seconds'], 25.944)
        self.assertGreater(request['wall_outside_accounted_yields_seconds'], 0)
        self.assertEqual(request['interruptions'], 0)

    def test_native_stage_and_cancellation_contract(self):
        events = rows(ROOT / 'screenshot-once/native-stages.jsonl')
        self.assertEqual([e['stage'] for e in events],
                         ['swift-entry', 'backend-begin', 'backend-end', 'model-begin'])
        self.assertEqual(len({e['pid'] for e in events}), 1)
        self.assertEqual([e['uptime'] for e in events], sorted(e['uptime'] for e in events))
        self.assertTrue(all(set(e) == {'pid', 'uptime', 'stage'} for e in events))
        trace = rows(ROOT / 'screenshot-once/trace.jsonl')
        self.assertTrue(any(e['stage'] == 'media-error' and e['error'] == 'CancellationError()' for e in trace))
        self.assertTrue(any(e['stage'] == 'media-ownership-retired' and not e['occupied'] for e in trace))
        snapshots = json.loads((ROOT / 'screenshot-once/process-and-persistence.json').read_text())
        self.assertTrue(all(not s.get('media_segments') and not s.get('chunks') for s in snapshots))

    def test_diagnostic_copy_preserves_product_code(self):
        source = (ROOT / 'semantic_helper.swift').read_text()
        product = (ROOT.parents[5] / 'Sources/TypefluxSemanticHelper/main.swift').read_text()
        # Remove the complete added logger and fixed call sites, then compare all executable code.
        start = source.index('// Diagnostic copy only.')
        end = source.index('// Private disposable helper.')
        source = source[:start] + source[end:]
        source = source.replace('import Darwin\n', '')
        source = source.replace('} catch { diagnosticStage("fatal-error"); exit(1) }', '} catch { exit(1) }')
        source = re.sub(r'^\s*diagnosticStage\("[a-z-]+"\)\n', '', source, flags=re.MULTILINE)
        self.assertEqual([s for s in source.splitlines() if s.strip()],
                         [s for s in product.splitlines() if s.strip()])

    def test_cpu_time_parser(self):
        self.assertAlmostEqual(cpu_seconds('0:00.04'), .04)
        self.assertAlmostEqual(cpu_seconds('12:30.50'), 750.5)
        self.assertAlmostEqual(cpu_seconds('1:02:03.25'), 3723.25)


if __name__ == '__main__':
    unittest.main(verbosity=2)
