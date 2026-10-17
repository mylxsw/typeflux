"""Artifact integrity and rejection-attribution checks; these do not claim product acceptance."""
import json
from pathlib import Path
import unittest
from analyze import analyze, unit_vector

HERE = Path(__file__).resolve().parent


class DiagnosisTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.result = analyze(HERE)
        cls.replay = json.loads((HERE / 'offline-replay.json').read_text())

    def test_persisted_bytes_and_quantization_do_not_explain_rejection(self):
        image = next(r for r in self.result['rows'] if r['segment_kind'] == 'image')
        self.assertTrue(image['generated_float32_bytes_equal_persisted'])
        self.assertTrue(all(abs(r['quantization_delta']) < 1e-4 for r in self.result['rows']))
        self.assertEqual(self.result['pipeline_counts'], dict(persisted_vectors=2, compatible_vectors=2,
            eligible_vectors=2, accepted_scores=2, distinct_files=1, after_confidence=0))
        self.assertFalse(self.result['product_complete'])
        self.assertEqual(self.replay['fixed_query']['hits'], [])

    def test_existing_negative_denominators_and_exact_lexical_gates(self):
        self.assertEqual(self.result['existing_no_answer_denominator'], 50)
        self.assertEqual(self.result['existing_no_answer_false_positives'], 0)
        self.assertEqual([len(r['hits']) for r in self.replay['exact_lexical_queries']], [1, 0, 1, 0])
        groups = [r['group'] for r in self.replay['no_answer_rows']]
        self.assertEqual(groups.count('no_answer'), 25)
        self.assertEqual(groups.count('media_no_answer'), 25)

    def test_scalar_cutoff_cannot_separate_fixed_positive_and_existing_wrong_color(self):
        self.assertTrue(self.result['single_absolute_threshold_cannot_accept_fixed_and_reject_this_color_pair'])
        self.assertFalse(self.result['stronger_nonmatching_color']['matches_frozen_target'])
        pairs = self.replay['existing_image_color_pairs']
        self.assertEqual(sum(r['matches_frozen_target'] for r in pairs), 6)
        self.assertTrue(all(r['single_file_confident'] == r['matches_frozen_target'] for r in pairs))

    def test_script_ordering_does_not_bypass_absolute_confidence(self):
        self.assertEqual(self.result['winning_segment_if_confident'], 'image-ocr')
        image, ocr = self.result['rows']
        self.assertEqual(image['script_adjustment'], 0)
        self.assertEqual(ocr['script_adjustment'], .025)
        self.assertGreater(ocr['ordered_candidate_score'], image['ordered_candidate_score'])
        self.assertFalse(self.replay['fixed_query']['diagnosis']['confident'])
        self.assertEqual(self.replay['fixed_query']['hits'], [])

    def test_invalid_vector_artifacts_fail_instead_of_reporting_valid_scores(self):
        for values in [[0.0] * 767, [0.0] * 768, [float('nan')] * 768, [float('inf')] * 768]:
            with self.subTest(length=len(values)), self.assertRaises(ValueError):
                unit_vector(values)


if __name__ == '__main__':
    unittest.main()
