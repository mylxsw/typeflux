#!/usr/bin/env python3
"""Preserve every missing positive, false positive and row regression across all holdouts."""
import json
import math
from pathlib import Path

folder = Path(__file__).parent
observations = {
    'final_cross_language-05': 'The English equivalent and audio precede the labelled Chinese original; an unrelated English museum record also precedes it. The exact-source label remains rank 4. This is ordering regression, not a missing extraction.',
    'final_semantic_paraphrase-17': 'An unrelated tripod record ranks first, followed by the English audio equivalent; the required Chinese hand-tool source falls from rank 2 to 3. Cross-modal semantic similarity is insufficient to guarantee the labelled original ordering.',
    'unseen_no_answer-01': 'The corpus has no piezoelectric-resonance answer. Related technical/general records survive absolute and margin confidence checks. The labelled no-answer failure remains 1/25 for this cohort.',
    'unseen_semantic_paraphrase-18': 'The expected English recording-publication source falls outside the five returned hits, behind audio and competing sources. An equivalent audio hit does not satisfy the frozen exact-source/location label; preserve the lost recall and location.',
    'fresh-semantic_paraphrase-01': 'The equivalent English wristband source now precedes the required Chinese source. The Chinese answer is present at rank 2; exact-source MRR declines.',
    'fresh-semantic_paraphrase-09': 'The equivalent English dance-shoe source now precedes the required Chinese source. The Chinese answer is present at rank 2; exact-source MRR declines.',
    'fresh-semantic_paraphrase-17': 'The equivalent English rain-gauge source now precedes the required Chinese source. The Chinese answer is present at rank 2; exact-source MRR declines.',
    'fresh-semantic_paraphrase-21': 'The equivalent English binding-brush source now precedes the required Chinese source. The Chinese answer is present at rank 2; exact-source MRR declines.',
    'fresh-no_answer-18': 'The impossible Saturn-vault query returns generic foil records and audio despite no labelled answer. Their high captured cosine defeats the absolute-confidence rule; retain this false positive.',
    'fresh-no_answer-24': 'The fictional time-reversal serial-code query returns generic foil records and audio. Unsupported identifier-like semantic similarity is accepted without literal answer evidence; together these negatives make this cohort 2/25 (8%).',
    'final2-audio_semantic-01': 'The source is an actual generated speech recording encoded on the CPU backend. The explicit-audio query is rejected by final confidence filtering and returns no results. Baseline rank 2 becomes a missing positive; this keeps audio Recall@5 at 24/25.',
    'final2-cross_language-10': 'The Chinese equivalent and English audio precede the labelled English shell source. The answer remains present at rank 3; this row regresses even though group MRR improves.',
    'final2-semantic_paraphrase-10': 'The Chinese equivalent precedes the required English shell source. The English answer remains at rank 2; preserve this row regression within the otherwise improved semantic group.',
}
rows = []
summary = {}
for fixture in ['final-holdout', 'unseen-query', 'rework-frozen', 'rework-final2']:
    captures = json.loads((folder / (fixture + '-vectors.json')).read_text())
    queries = {x['id']: x for x in captures['queries']}
    docs = {x['id']: x for x in captures['documents']}
    reports = {label: json.loads((folder / f'ranking-{label}-final-{fixture}.json').read_text())['rows']
               for label in ['before', 'after']}
    before = {x['id']: x for x in reports['before']}
    summary[fixture] = {}
    for group in sorted(set(x['group'] for x in reports['after'])):
        summary[fixture][group] = {}
        for label, report in reports.items():
            selected = [x for x in report if x['group'] == group]
            positives = [x for x in selected if x['expected']]
            negatives = [x for x in selected if not x['expected']]
            summary[fixture][group][label] = dict(n=len(selected), positive_n=len(positives), negative_n=len(negatives),
                recall_at_5=sum(x.get('rank') is not None for x in positives) / len(positives) if positives else None,
                mrr=sum(1 / x['rank'] if x.get('rank') else 0 for x in positives) / len(positives) if positives else None,
                location=sum(bool(x['location_correct']) for x in positives) / len(positives) if positives else None,
                false_positives=sum(bool(x['hits']) for x in negatives),
                false_positive_rate=sum(bool(x['hits']) for x in negatives) / len(negatives) if negatives else None)
    for current in reports['after']:
        old = before[current['id']]
        missing = bool(current['expected']) and current.get('rank') is None
        regression = old.get('rank') is not None and (current.get('rank') or math.inf) > old['rank']
        false_positive = not current['expected'] and bool(current['hits'])
        if not (missing or regression or false_positive):
            continue
        query = queries[current['id']]
        vector = query['vector']
        def cosine(doc):
            other = doc['vector']
            return sum(a * b for a, b in zip(vector, other)) / math.sqrt(sum(x*x for x in vector) * sum(x*x for x in other))
        ordered = sorted(((cosine(doc), doc) for doc in docs.values()), key=lambda x: x[0], reverse=True)
        def content(identity):
            doc = docs[identity]
            return dict(id=identity, kind=doc['kind'], text=doc.get('text', ''))
        rows.append(dict(fixture=fixture, id=current['id'], group=current['group'], query=query['query'],
                         expected=current['expected'], before_rank=old.get('rank'), after_rank=current.get('rank'),
                         missing_positive=missing, row_regression=regression, false_positive=false_positive,
                         hits=current['hits'], location_correct=current['location_correct'],
                         raw_peak=ordered[0][0], raw_distinct_source_margin=ordered[0][0]-ordered[1][0],
                         raw_top_sources=[dict(id=d['id'], cosine=c, kind=d['kind']) for c,d in ordered[:5]],
                         target_sources=[content(x) for x in current['expected']],
                         returned_sources=[content(x) for x in current['hits']],
                         observation=observations[current['id']]))
(folder / 'final-ranking-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
(folder / 'final-heldout-failures.json').write_text(json.dumps(dict(
    scope='Authoritative final Release Swift ranking; all 800 held-out rows and original denominators retained. Every missing positive, false positive and row regression is included. Captured cosine is diagnostic replay, not a new end-to-end measurement. Sources are synthetic. No tuning on these labels.',
    rows=rows), indent=2) + '\n')
print(json.dumps(dict(holdout_rows=sum(len(json.loads((folder/f'ranking-after-final-{x}.json').read_text())['rows']) for x in summary), failures=len(rows))))
