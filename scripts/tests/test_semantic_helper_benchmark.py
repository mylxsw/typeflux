"""The benchmark protocol is tested with synthetic children; these are not model measurements."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("semantic_benchmark", ROOT / "scripts/semantic_helper_benchmark.py")
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)
fixture_spec = importlib.util.spec_from_file_location("semantic_fixture", ROOT / "scripts/create_semantic_query_fixture.py")
fixture_module = importlib.util.module_from_spec(fixture_spec)
fixture_spec.loader.exec_module(fixture_module)


class SemanticBenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="semantic-benchmark-test-")
        self.root = Path(self.directory.name)
        self.model = self.root / "model"
        self.model.write_bytes(b"synthetic model")
        self.hash_patch = patch.object(benchmark, "MODEL_SHA256", hashlib.sha256(self.model.read_bytes()).hexdigest())
        self.hash_patch.start()

    def tearDown(self):
        self.hash_patch.stop()
        self.directory.cleanup()

    def helper(self, response=None, ending=""):
        child = self.root / "helper"
        response = response if response is not None else {"embeddings": [[1.0] + [0.0] * 767]}
        child.write_text("#!/usr/bin/env python3\nimport sys,json\nfor line in sys.stdin:\n"
                         f" print({json.dumps(json.dumps(response))},flush=True)\n" + ending)
        child.chmod(0o700)
        return child

    def test_cold_and_one_hundred_warm_samples_have_separate_percentiles(self):
        report = benchmark.measure(self.helper(), self.model)
        self.assertEqual(len(report["samples_ms"]), 101)
        self.assertEqual(report["samples"], 100)
        self.assertGreater(report["warm_p95_ms"], 0)
        self.assertEqual(benchmark.percentile([4, 2, 1, 3], 0.5), 3)
        self.assertEqual(report["indexing_concurrency"], 0)
        self.assertGreater(report["child_max_rss_bytes"], 0)

    def test_cli_writes_raw_samples_but_does_not_print_them_or_queries(self):
        output = self.root / "report/result.json"
        args = ["semantic_helper_benchmark.py", "--helper", str(self.helper()), "--model", str(self.model),
                "--report", str(output)]
        printed = io.StringIO()
        with patch("sys.argv", args), contextlib.redirect_stdout(printed):
            benchmark.main()
        self.assertEqual(len(json.loads(output.read_text())["samples_ms"]), 101)
        self.assertNotIn("samples_ms", json.loads(printed.getvalue()))
        self.assertNotIn("How can", printed.getvalue())

    def test_bad_checksum_count_protocol_norm_timeout_and_exit_fail_explicitly(self):
        with self.assertRaises(ValueError):
            benchmark.measure(self.helper(), self.model, 99)
        with patch.object(benchmark, "MODEL_SHA256", "unexpected"), self.assertRaises(ValueError):
            benchmark.measure(self.helper(), self.model)
        for vector in [[0], [0.0] * 768, [float("nan")] * 768]:
            with self.subTest(vector=vector[:1]), self.assertRaises(ValueError):
                benchmark.measure(self.helper({"embeddings": [vector]}), self.model)
        child = self.helper()
        with patch.object(benchmark.select, "select", return_value=([], [], [])), self.assertRaises(TimeoutError):
            benchmark.measure(child, self.model)
        child.write_text("#!/usr/bin/env python3\n")
        with self.assertRaises(ValueError):
            benchmark.measure(child, self.model)
        with self.assertRaises(ValueError):
            benchmark.measure(self.helper(ending="sys.exit(1)\n"), self.model)

    def test_fixture_labels_are_unique_and_traceable_to_hand_authored_sources(self):
        fixture = fixture_module.fixture()
        documents = {document["id"]: document for document in fixture["documents"]}
        self.assertEqual(len(fixture["queries"]), 200)
        self.assertEqual(len({row["id"] for row in fixture["queries"]}), 200)
        self.assertEqual(sum(not row["baseline_supported"] for row in fixture["queries"]), 75)
        for query in fixture["queries"]:
            for expected in query["expected"]:
                self.assertIn(query["anchor"], documents[expected]["text"])


if __name__ == "__main__":
    unittest.main()
