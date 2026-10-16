#!/usr/bin/env python3
"""Capture short, absent-topic development queries without opening held-out fixtures."""
import argparse, hashlib, importlib.util, json, time
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--helper', type=Path, required=True)
p.add_argument('--model', type=Path, required=True)
a = p.parse_args()
h = Path(__file__).parent
target = h / 'development-negatives-v3.json'
assert not target.exists(), 'Captured evidence is immutable'
subjects = [
    'the invisible continent', 'a singing asteroid', 'the transparent elephant',
    'a perpetual motion engine', 'the vanished rainbow palace', 'a miniature ocean',
    'the golden moon rabbit', 'a telepathic cactus', 'the underground cloud city',
    'a floating crystal island', 'the silent thunder drum', 'a paper galaxy',
    'the missing star crown', 'a weightless diamond', 'the sleeping volcano dragon',
    'a luminous snowflake', 'the underwater desert', 'a magnetic butterfly',
    'the frozen rainbow', 'a talking stone',
]
queries = []
for subject in subjects:
    for template in ['Who discovered {s}?', 'Where is {s} located?', 'How does {s} work?']:
        queries.append(dict(id=f'dev-short-{len(queries):03}', group='development_short_no_answer',
                            query=template.format(s=subject), expected=[]))
for subject in ['隐形大陆', '会唱歌的小行星', '透明大象', '永动引擎', '彩虹宫殿', '微型海洋',
                '月亮金兔', '会读心的仙人掌', '地下云城', '悬浮水晶岛', '无声雷鼓', '纸银河',
                '失踪星冠', '无重量钻石', '沉睡火山龙', '发光雪花', '水下沙漠', '磁力蝴蝶',
                '冰冻彩虹', '会说话的石头']:
    for template in ['谁发现了{subject}？', '{subject}在哪里？', '{subject}的原理是什么？']:
        queries.append(dict(id=f'dev-short-{len(queries):03}', group='development_short_no_answer',
                            query=template.format(subject=subject), expected=[]))
labels = dict(queries=queries, scope='120 short development negatives, English and Chinese. '
              'All subjects are absent from development sources. No frozen fixture is opened.')
(h / 'development-negatives-v3-labels.json').write_text(json.dumps(labels, ensure_ascii=False, indent=2)+'\n')
spec = importlib.util.spec_from_file_location('ipc', h / 'measure_batch.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
start = time.monotonic(); worker = m.Worker([a.helper.resolve(), a.model.resolve()])
try:
    for q in queries:
        reply, ms = worker.request(dict(texts=['task: search result | query: '+q['query']]))
        assert not reply.get('error'), reply
        q['vector'] = reply['embeddings'][0]; q['ipc_ms'] = ms
    result = dict(**labels, helper_sha256=hashlib.sha256(a.helper.read_bytes()).hexdigest(),
                  model_sha256=hashlib.sha256(a.model.read_bytes()).hexdigest(), wall_seconds=time.monotonic()-start)
    target.write_text(json.dumps(result, ensure_ascii=False)+'\n')
    print('Captured', len(queries), 'development negatives', result['wall_seconds'])
finally:
    worker.close()
