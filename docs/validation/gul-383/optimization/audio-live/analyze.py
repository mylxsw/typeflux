"""Recompute the retained media observations without loading a model or changing the oracle."""
import hashlib
import json
import math
from pathlib import Path
import sqlite3
import struct
import time

started = time.monotonic()
here = Path(__file__).resolve().parent
load = lambda path: json.loads(path.read_text())
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
audio = here / 'live-visible-root'
video = here / 'video-live'
report = load(audio / 'report.json')
trace = [json.loads(line) for line in (audio / 'trace.jsonl').read_text().splitlines()]
requests = [r for r in trace if r['stage'] == 'media-request']
assert [(r['time'], r['end_time']) for r in requests] == [(0, 30), (25, 55)]
assert len([r for r in trace if r['stage'] == 'media-response']) == 2
assert report['resume_requested'] and report['ready'] and not report['complete']
assert report['queries'] == [{'query': 'a tone', 'hits': []}]
assert report['reopened_query']['hits'] == []
assert any(item['audio_covered'] == 30 and item['media_segments'] == 1
           for row in report['snapshots'] for item in row['items'])
with sqlite3.connect('file:' + str(audio / 'final.sqlite') + '?immutable=1', uri=True) as database:
    rows = database.execute('SELECT time,end_time,segment_kind,provenance,vector FROM chunks ORDER BY time').fetchall()
query = load(audio / 'query-vector.json')
assert len(query) == 768
vectors = [list(struct.unpack('<768f', row[4])) for row in rows]
assert [(r[0], r[1], r[2]) for r in rows] == [(0, 30, 'audio-window'), (25, 55, 'audio-window')]
cosines = []
for row, vector in zip(rows, vectors):
    assert len(vector) == 768 and all(math.isfinite(v) for v in vector)
    assert abs(sum(v*v for v in vector) - 1) < 0.00001
    generated = load(audio / ('audio-vector-' + str(int(row[0])) + '.json'))
    assert max(abs(a-b) for a, b in zip(vector, generated)) < 0.0000001
    cosine = sum(a*b for a, b in zip(vector, query))
    compact = [struct.unpack('<e', struct.pack('<e', v))[0] for v in vector]
    scanner = sum(a*b for a, b in zip(compact, query))
    cosines.append(dict(time=row[0], end_time=row[1], raw_float32_dot=cosine, compact_dot=scanner))
assert max(r['compact_dot'] for r in cosines) < 0.70
live = load(here / 'live-query-prepared/report.json')
assert live['complete'] and live['actual_file_metadata'] and live['live_query']
assert live['service'][0]['name'] == live['reopened'][0]['name'] == 'boundary.wav'
assert live['service'][0]['time'] == live['reopened'][0]['time'] == 25
fresh = load(here / 'live-query-prepared/fresh-query-vector.json')
assert len(fresh) == 768 and max(abs(a-b) for a, b in zip(query, fresh)) < 0.000001
mixed = load(here / 'offline-replay.json')
assert len(mixed['rows']) == 306 and mixed['no_answer_denominator'] == 50 and mixed['false_positives'] == 0
assert all(mixed['recalled'][group] / count >= 0.85 for group, count in mixed['positive_denominators'].items())
assert sha(video / 'scene.mov') == '7db4b38eca51b68f458481fee84c1aa5a3e119e5e29d9faf166a035bbd99ddd2'
v = load(video / 'report.json')
assert v['complete'] and v['resume_requested']
assert v['queries'][0]['query'] == 'blue slide'
assert v['queries'][0]['hits'][0]['time'] == v['reopened_query']['hits'][0]['time'] == 1.5
assert v['queries'][0]['hits'][0]['kind'] == 'video-frame'
with sqlite3.connect('file:' + str(video / 'final.sqlite') + '?immutable=1', uri=True) as database:
    frames = database.execute('SELECT time,segment_kind,length(vector) FROM chunks ORDER BY time').fetchall()
assert frames == [(0, 'video-frame', 3072), (1.5, 'video-frame', 3072), (2, 'video-frame', 3072), (5.9, 'video-frame', 3072)]
video_trace = [json.loads(line) for line in (video / 'trace.jsonl').read_text().splitlines()]
progress = [r for r in video_trace if r['stage'] == 'decoded-video-progress']
assert len(progress) == 14 and len(set(r['actual'] for r in progress)) == 13
assert progress[-1]['actual'] == 5.9 and progress[-1]['complete']
assert len([r for r in video_trace if r['stage'] == 'media-request']) == 5
assert len([r for r in video_trace if r['stage'] == 'media-response']) == 4
assert any(r['stage'] == 'media-error' for r in video_trace)
assert any(r['stage'] == 'media-ownership-retired' and not r['occupied'] for r in video_trace)
result = dict(audio_live_window_cosines=cosines, audio_single_file_rejected=True,
              audio_retained_vectors_live_query_actual_metadata=True, audio_hit_window=[25, 55],
              fixed_rows=306, no_answer=dict(false_positives=0, denominator=50),
              positive_denominators=mixed['positive_denominators'], recalled=mixed['recalled'],
              video_actual_retained_times=[r[0] for r in frames], video_hit_time=1.5,
              video_unique_decode_times=13, video_decode_callbacks=14,
              video_requests=5, video_returned_vectors=4, cancelled_uncommitted_request=1,
              video_wrapper_exit_status=1, video_product_report_complete=True,
              scope='Raw/compact arithmetic and production report verification. Video observer exited nonzero after product completion; its two focused child-exit regressions pass. No threshold, model, label or product changes.',
              wall_seconds=time.monotonic()-started)
(here / 'analysis.json').write_text(json.dumps(result, indent=2)+'\n')
print('Audio generation/resume and live existing-corpus query verified; video product evidence verified; observer failure disclosed; original306/no-answer0/50 retained')
