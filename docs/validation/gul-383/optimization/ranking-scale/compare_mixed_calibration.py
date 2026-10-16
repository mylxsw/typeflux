#!/usr/bin/env python3
"""Compare frozen choices on development queries over the complete mixed corpus.

Does not read final-holdout or unseen-query artifacts. Their results never select weights.
This Python sensitivity harness is approximate; production Swift replay is authoritative.
"""
import importlib.util
import json
import os
from pathlib import Path

HERE = Path(__file__).parent
partial_penalty = float(os.environ.get('TYPEFLUX_DEV_PARTIAL_PENALTY', '0.18'))
assert partial_penalty in [0, 0.18]
variant = '-monotonic' if partial_penalty == 0 else ''
spec = importlib.util.spec_from_file_location('calibration', HERE / 'calibrate.py')
calibration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(calibration)
text = json.loads((HERE / 'raw-quality-vectors.json').read_text())
media = json.loads((HERE / 'captured-media.json').read_text())
corpus = list(zip(text['documents'], text['vectors'])) + [(d, d['vector']) for d in media['documents']]
prepared = []
for query in text['queries'] + media['queries']:
    if query['group'] in ['scanned', 'media_timestamp']:
        continue
    vector = query.get('vector') or text['query_vectors'][query['id']]
    rows = []
    for document, source in corpus:
        kind = document['kind'] if document['kind'] in ['audio', 'image'] else 'text'
        script = sum('\u3400' <= c <= '\u9fff' for c in document['text']) >= 2
        bucket = 'cjk' if kind == 'text' and script else kind
        coverage, phrase, identifier, exact = calibration.features(query['query'], document['text'] if kind == 'text' else '')
        accepted = exact if identifier else coverage >= .5
        if identifier and not exact:
            continue
        if not accepted:
            coverage, phrase = 0, False
        cosine = sum(a * b for a, b in zip(vector, source))
        lexical = .3 * coverage**2 + .12 * phrase + .35 * (coverage == 1) - partial_penalty * (0 < coverage < 1)
        hint = .04 if kind == 'image' and any(x in query['query'].split() for x in ['photo', 'image']) else 0
        rows.append(dict(id=document['id'], cosine=cosine, lexical=lexical, accepted=accepted,
                         complete=coverage == 1, exact=exact, kind=kind, bucket=bucket, hint=hint))
    prepared.append((query, rows))
reports = {}
for method in ['rrf', 'coverage-fusion', 'script-modality-centered']:
    output, groups = [], {}
    for query, rows in prepared:
        peaks = sorted((r['cosine'] for r in rows), reverse=True)
        confident = any(r['complete'] for r in rows) or (peaks and peaks[0] >= .675) or (len(peaks) > 1 and peaks[0] >= .45 and peaks[0] - peaks[1] >= .04)
        candidates = [dict(r) for r in rows if r['accepted'] or (r['cosine'] >= .45 and confident)]
        shared = sum(r['cosine'] for r in rows) / len(rows) if rows else 0
        for row in candidates:
            adjustment = 0
            if method == 'script-modality-centered':
                bucket = [r['cosine'] for r in rows if r['bucket'] == row['bucket']]
                adjustment = .55 * len(bucket) / (len(bucket) + 4) * (shared - sum(bucket) / len(bucket))
            row['score'] = 1 + .01 * row['cosine'] if row['exact'] else .55 * max(0, row['cosine']) + row['lexical'] + row['hint'] + (.05 if row['kind'] == 'audio' else 0) + adjustment
        if method == 'rrf':
            vectors = {r['id']: i + 1 for i, r in enumerate(sorted(candidates, key=lambda r: -r['cosine']))}
            lexical = {r['id']: i + 1 for i, r in enumerate(sorted((r for r in candidates if r['accepted']), key=lambda r: -r['lexical']))}
            for row in candidates:
                row['score'] = 1 / (60 + vectors[row['id']]) + (1 / (60 + lexical[row['id']]) if row['id'] in lexical else 0)
        candidates.sort(key=lambda r: (-r['score'], r['id']))
        hits = [r['id'] for r in candidates[:5]]
        rank = next((i + 1 for i, item in enumerate(hits) if item in query['expected']), None)
        output.append(dict(id=query['id'], group=query['group'], hits=hits, rank=rank))
        group = groups.setdefault(query['group'], dict(n=0, correct=0, rr=0, false_positive=0))
        group['n'] += 1; group['correct'] += rank is not None
        group['rr'] += 1 / rank if rank else 0
        group['false_positive'] += bool(hits) and not query['expected']
    for group in groups.values():
        group['recall_at_5'] = group['correct'] / group['n']
        group['mrr'] = group['rr'] / group['n']
        group['false_positive_rate'] = group['false_positive'] / group['n']
    reports[method] = dict(groups=groups, rows=output)
report = dict(corpus_documents=len(corpus), queries=len(prepared), parameters=dict(semantic_floor=.45, absolute=.675, margin=.04, audio_offset=.05, shared_observations=4),
              selection='Fixed parameters from development calibration. Compare full mixed corpus; no held-out query results read. Original scan/media_timestamp groups remain unsupported failures in the 200-query production oracle report.', methods=reports)
(HERE / ('mixed-calibration-comparison' + variant + '.json')).write_text(json.dumps(report, indent=2) + '\n')
for method, data in reports.items():
    print(method, {name: [g['correct'], g['n'], round(g['mrr'], 3), g['false_positive']] for name, g in data['groups'].items()})
