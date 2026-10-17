"""Recompute retained real-vector diagnostics without a model, process, or threshold change."""
from contextlib import closing
import json
import math
from pathlib import Path
import sqlite3
import struct


def unit_vector(values):
    if len(values) != 768 or not all(math.isfinite(v) for v in values):
        raise ValueError('invalid dimensions or non-finite vector')
    norm = math.sqrt(sum(v * v for v in values))
    if abs(norm - 1) >= .02:
        raise ValueError('non-unit vector')
    return norm


def analyze(here):
    capture = here / 'fixed-capture'
    report = json.loads((capture / 'report.json').read_text())
    replay = json.loads((here / 'offline-replay.json').read_text())
    query_json = json.loads((capture / 'query-vector.json').read_text())
    unit_vector(query_json)
    query = list(struct.unpack('<768f', struct.pack('<768f', *query_json)))
    generated = json.loads((capture / 'image-generated-vector.json').read_text())
    unit_vector(query)
    with closing(sqlite3.connect('file:' + str(capture / 'synthetic.sqlite') + '?mode=ro&immutable=1', uri=True)) as db:
        assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        records = db.execute('SELECT id,path,vector,modality,segment_kind,provenance FROM chunks ORDER BY id').fetchall()
        versions = db.execute('SELECT path,version FROM files').fetchall()
    rows = []
    for record in records:
        ident, path, blob, modality, kind, provenance = record
        if len(blob) != 768 * 4:
            raise ValueError('invalid persisted vector byte count')
        values = struct.unpack('<768f', blob)
        norm = unit_vector(values)
        dot = sum(a * b for a, b in zip(values, query))
        observed = next(r for r in replay['fixed_query']['diagnosis']['rows'] if r['id'] == ident)
        assert abs(dot - observed['float32_dot']) < 1e-7
        rows.append(dict(id=ident, path=path, modality=modality, segment_kind=kind,
                         provenance=provenance, norm=norm, float32_dot=dot,
                         scanner_cosine=observed['scanner_cosine'],
                         quantization_delta=observed['scanner_cosine'] - dot,
                         script_adjustment=observed['script_adjustment'],
                         ordered_candidate_score=observed['ordered_candidate_score'],
                         generated_float32_bytes_equal_persisted=(struct.pack('<768f', *generated) == blob)
                         if kind == 'image' else None))
    visual = next(r for r in rows if r['segment_kind'] == 'image')
    wrong_color = max((r for r in replay['existing_image_color_pairs'] if not r['matches_frozen_target']),
                      key=lambda r: r['scanner_cosine'])
    negatives = replay['no_answer_rows']
    return dict(
        mode='Diagnostic analysis; current fixed query remains an acceptance failure',
        query_norm=unit_vector(query), rows=rows, file_versions=versions,
        pipeline_counts=dict(persisted_vectors=len(records), compatible_vectors=sum(r['provenance_matches'] for r in report['diagnosis']['rows']),
            eligible_vectors=sum(r['allowed'] for r in report['diagnosis']['rows']),
            accepted_scores=sum(r['candidate_score'] is not None for r in report['diagnosis']['rows']),
            distinct_files=report['diagnosis']['distinct_files'], after_confidence=len(report['reopened_query']['hits'])),
        winning_segment_if_confident=max(rows, key=lambda row: row['ordered_candidate_score'])['segment_kind'],
        first_rejection='SemanticSearchRanking.confident: no complete lexical evidence, no distinct runner-up, peak below 0.70',
        missing_absolute_margin=.70 - report['diagnosis']['peak'],
        existing_no_answer_denominator=replay['existing_no_answer_denominator'],
        existing_no_answer_false_positives=replay['existing_no_answer_false_positives'],
        maximum_existing_no_answer_cosine=max(r['diagnosis']['peak'] for r in negatives),
        stronger_nonmatching_color=wrong_color,
        single_absolute_threshold_cannot_accept_fixed_and_reject_this_color_pair=(wrong_color['scanner_cosine'] >= visual['scanner_cosine']),
        oracle_note='Original 25 no_answer plus existing 25 media_no_answer replayed on this one screenshot only. Original labels and denominator retained; no full-corpus quality claim. Color pairs are diagnostics, not added to the no-answer denominator.',
        product_complete=report['complete'])


if __name__ == '__main__':
    here = Path(__file__).resolve().parent
    result = analyze(here)
    (here / 'analysis.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ['rows', 'file_versions']}, indent=2))
