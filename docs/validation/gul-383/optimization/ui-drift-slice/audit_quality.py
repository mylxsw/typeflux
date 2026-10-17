"""Reconcile original frozen cohorts without changing labels or hiding failures."""
import hashlib
import json
import math
from pathlib import Path
import subprocess
import tarfile

ROOT = Path.cwd()
OUT = Path(__file__).resolve().parent
HISTORY = OUT.parent / 'ranking-scale'
COHORTS = ['final-holdout', 'unseen-query', 'rework-frozen', 'rework-final2', 'rework-final3']


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def counts(rows):
    positives = [row for row in rows if row['expected']]
    negatives = [row for row in rows if not row['expected']]
    recalled = sum(row.get('rank') is not None for row in positives)
    false_positives = sum(bool(row['hits']) for row in negatives)
    return {'rows': len(rows), 'recalled': recalled, 'positives': len(positives),
            'recall_at_5': recalled / len(positives), 'false_positives': false_positives,
            'negatives': len(negatives), 'false_positive_rate': false_positives / len(negatives),
            'mrr': sum(1 / row['rank'] if row.get('rank') else 0 for row in positives) / len(positives),
            'location_correct': sum(bool(row['location_correct']) for row in positives)}


def audit():
    artifacts = {}
    archive_bytes = (HISTORY / 'evidence-history.tar.gz').read_bytes()
    archive_manifest = json.loads((HISTORY / 'evidence-archive-manifest.json').read_bytes())
    assert sha(archive_bytes) == archive_manifest['sha256']
    with tarfile.open(HISTORY / 'evidence-history.tar.gz') as archive:
        def read(name):
            path = HISTORY / name
            raw = path.read_bytes() if path.is_file() else archive.extractfile('ranking-scale/' + name).read()
            artifacts[name] = {'sha256': sha(raw), 'bytes': len(raw),
                               'location': 'ranking-scale/' + name if path.is_file()
                               else 'ranking-scale/evidence-history.tar.gz!ranking-scale/' + name}
            return raw

        provenance = json.loads(read('final-ui-ranking-provenance.json'))
        command = json.loads(read('rework-run-ranking-after-100000-ui-final.json'))
        current_summary = json.loads((HISTORY / 'final-current-ranking-summary.json').read_bytes())
        cohorts = []
        for cohort in COHORTS:
            raw_labels = read(cohort + '-labels.json')
            labels = json.loads(raw_labels)
            raw_capture = read(cohort + '-vectors.json')
            capture = json.loads(raw_capture)
            assert capture['model_sha256'] in (ROOT / 'Sources/Typeflux/Ask/QuickResults/Semantic/SemanticEmbeddingWorker.swift').read_text()
            assert capture['projector_sha256'] in (ROOT / 'Sources/Typeflux/Ask/QuickResults/Semantic/SemanticMediaWorker.swift').read_text()
            report = json.loads(read('ranking-after-ui-final-' + cohort + '.json'))
            assert capture['labels_sha256'] == sha(raw_labels)
            assert provenance['captures'][cohort] == sha(raw_capture)
            expected = {row['id']: row for row in labels['queries']}
            assert len(expected) == len(capture['queries']) == len(report['rows']) == 200
            assert len({row['id'] for row in report['rows']}) == 200
            # The query-only unseen cohort explicitly reuses the final-holdout sources.
            source_labels = labels if 'documents' in labels else json.loads(read('final-holdout-labels.json'))
            documents = {row['id']: row for row in source_labels['documents']}
            captured_documents = {row['id']: row for row in capture['documents']}
            assert documents.keys() == captured_documents.keys()
            for identity, document in documents.items():
                other = captured_documents[identity]
                assert all(document[key] == other[key] for key in ['kind', 'text'])
            for row in capture['queries']:
                assert all(row[key] == expected[row['id']][key] for key in ['query', 'group', 'expected'])
                assert all(identity in documents for identity in row['expected'])
            for row in report['rows']:
                assert all(row[key] == expected[row['id']][key] for key in ['group', 'expected'])
                rank = next((i + 1 for i, identity in enumerate(row['hits']) if identity in row['expected']), None)
                assert row['rank'] == rank
            for row in capture['documents'] + capture['queries']:
                assert len(row['vector']) == 768 and all(math.isfinite(x) for x in row['vector'])
            result = counts(report['rows'])
            summary = current_summary[cohort]
            assert result['recalled'] == sum(round(group['after']['recall_at_5'] * group['after']['positive_n'])
                                              for group in summary.values() if group['after']['positive_n'])
            assert result['false_positives'] == sum(group['after']['false_positives'] for group in summary.values())
            cohorts.append({'cohort': cohort, 'historical': result,
                            'capture_model_sha256': capture['model_sha256'],
                            'capture_projector_sha256': capture['projector_sha256'],
                            'capture_helper_sha256': capture.get('helper_sha256'),
                            'media_sources_with_sha256': sum('sha256' in row for row in capture['documents']
                                                             if row['kind'] != 'text'),
                            'source_count': len(documents), 'label_and_capture_match': True,
                            'all_expected_sources_available_in_capture': True})
        measured_sources = command['production_sha256']
        comparison = {name: {'historical_sha256': old, 'current_sha256': sha((ROOT / name).read_bytes()),
                             'unchanged': old == sha((ROOT / name).read_bytes())}
                      for name, old in measured_sources.items()
                      if name.startswith('Sources/') and '/Semantic/' in name and (ROOT / name).is_file()}
        # Retain the actual harness source at the measured epoch; do not infer it from a report name.
        harness = 'Tests/TypefluxTests/SemanticRankingComparisonTests.swift'
        old_harness = subprocess.check_output(['git', 'show', provenance['source_commit'] + ':' + harness])
        harness_proof = {'historical_sha256': sha(old_harness), 'current_sha256': sha((ROOT / harness).read_bytes()),
                         'unchanged': old_harness == (ROOT / harness).read_bytes()}
        read('capture_final_holdout.py'); read('capture_unseen_queries.py'); read('capture_frozen_candidate.py')
        read('rework_release_runner.py')
        read('final-current-heldout-failures.json')
    fixed = json.loads((OUT.parent / 'visual-corroboration/mixed-oracle.json').read_bytes())
    positives = [row for row in fixed['rows'] if row['expected']]
    negatives = [row for row in fixed['rows'] if not row['expected']]
    assert len(fixed['rows']) == 306 and len(positives) == 256 and len(negatives) == 50
    recalled = sum(row.get('rank') is not None for row in positives)
    assert recalled == 202 and sum(bool(row['hits']) for row in negatives) == 0
    result = {'cohorts': cohorts, 'historical_source_commit': provenance['source_commit'],
              'historical_binary_sha256': command['binary_sha256'], 'historical_command_exit': command['exit_code'],
              'source_comparison': comparison, 'harness': harness_proof, 'artifacts': artifacts,
              'archive_sha256': sha(archive_bytes),
              'fixed_306': {'rows': 306, 'supported_recalled': 202, 'supported_positives': 206,
                            'all_recalled': 202, 'all_positives': 256, 'missing_source_failures': 50,
                            'false_positives': 0, 'negatives': 50, 'full_recall_gate_pass': False},
              'boundary': 'Each 200-row cohort remains separate historical quality evidence. Captured real vectors and fictional sources are reusable ranking inputs. Ranking/calibration files match, but vector-reader/image scoring and media recipes changed after historical execution; old results are not current extraction/UI/inference results. Exact current-result equivalence is not asserted. If required for final acceptance, the minimal supplement is the existing fixed-vector ranking harness on the original cohorts, without re-encoding, new labels, holdout or tuning. The 306-row full-positive recall remains below 85%.'}
    (OUT / 'quality-audit.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'cohorts': cohorts, 'fixed_306': result['fixed_306']}))


if __name__ == '__main__':
    audit()
