#!/usr/bin/env python3
"""Audit representation error on fixed real vectors; no ranking parameters are selected here."""
import hashlib
import json
import math
from pathlib import Path
import struct
import time

HERE = Path(__file__).parent
started = time.monotonic()
source = HERE / 'unseen-query-vectors.json'
raw = json.loads(source.read_text())
documents = raw['documents']
half = [[struct.unpack('e', struct.pack('e', value))[0] for value in doc['vector']]
        for doc in documents]
rows = []
for query in raw['queries']:
    vector = query['vector']
    assert len(vector) == 768 and all(len(doc['vector']) == 768 for doc in documents)
    exact = [sum(a*b for a, b in zip(vector, doc['vector'])) for doc in documents]
    compact = [sum(a*b for a, b in zip(vector, value)) for value in half]
    top = lambda values: [documents[index]['id'] for index in
                          sorted(range(len(values)), key=lambda index: (-values[index], documents[index]['id']))[:5]]
    original, quantized = top(exact), top(compact)
    rows.append(dict(id=query['id'], max_absolute_cosine_error=max(abs(a-b) for a, b in zip(exact, compact)),
                     raw_top5_float32_payload=original, raw_top5_float16_payload=quantized,
                     raw_top1_changed=original[0] != quantized[0], raw_top5_order_changed=original != quantized,
                     raw_top5_set_changed=set(original) != set(quantized)))
errors = sorted(row['max_absolute_cosine_error'] for row in rows)
report = dict(source=source.name, source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
              scope='Real captured Float32 query vectors and document payloads, double-precision dot accumulation for both representations. This isolates FP16 representation, not BLAS accumulation or final calibrated ranking. No model execution or UI timing.',
              queries=len(rows), documents=len(documents), max_absolute_cosine_error=max(errors),
              cosine_error_quantiles={f'p{p}': errors[math.ceil(p/100*len(errors))-1] for p in [50, 95, 99]},
              raw_top1_changes=sum(row['raw_top1_changed'] for row in rows),
              raw_top5_order_changes=sum(row['raw_top5_order_changed'] for row in rows),
              raw_top5_set_changes=sum(row['raw_top5_set_changed'] for row in rows),
              theoretical_matrix_bytes_per_million_rows=dict(float32=1000000*768*4, float16=1000000*768*2),
              page_float32_scratch_bytes=256*768*4, query_scalar_bytes_per_million_rows=4000000,
              wall_seconds=time.monotonic()-started, rows=rows)
(HERE/'quantization.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps({key:value for key,value in report.items() if key != 'rows'}))
