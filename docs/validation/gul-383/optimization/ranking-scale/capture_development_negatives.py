#!/usr/bin/env python3
"""Additional development-only abstention examples; no held-out labels or captures are opened."""
import argparse,hashlib,importlib.util,json,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--helper',type=Path,required=True);p.add_argument('--model',type=Path,required=True);a=p.parse_args();h=Path(__file__).parent;target=h/'development-negatives-v2.json'
assert not target.exists(),'Never overwrite captured development evidence'
subjects=['copper-winged meridian owl','invented cobalt orchard council','violet sand clock of Lyra','lost polar orchid monarchy','fictional pearl submarine academy','crimson cloud ferry guild','mythical cedar radio telescope','imaginary jade avalanche lantern','invented silver moth parliament','hidden ember chess observatory','fictional amber glacier theatre','mythical bronze hummingbird refinery','imaginary coral windmill university','invented sapphire cactus tribunal','fictional ivory thunder library','mythical scarlet comet bakery','imaginary onyx tide calendar','invented jade finch republic','fictional marble rain locomotive','mythical silver fern airship']
english=['Which research report establishes the exact age of the {s}?','Where is the missing documentary recording of the {s}?','What is the unrecorded medical treatment prescribed by the {s}?','Which image shows the unique secret emblem of the {s}?']
chinese=['哪份记录给出了虚构的{s}的准确出生地点？','哪里有虚构的{s}的演讲录音？']
chinese_subjects=['铜翼星盘猫头鹰','钴蓝果园议会','天琴紫砂时钟','极地兰花王朝','珍珠潜艇学院','赤云轮渡公会','雪松射电望远镜','翡翠雪崩灯笼','银蛾议会','余烬象棋天文台','琥珀冰川剧院','青铜蜂鸟炼油厂','珊瑚风车大学','蓝宝石仙人掌法庭','象牙雷鸣图书馆','朱红彗星面包房','玛瑙潮汐日历','翡翠雀鸟共和国','大理石雨滴火车','银蕨飞艇']
queries=[]
for n,s in enumerate(subjects):
 for template in english:queries.append(dict(id=f'dev-extra-en-{len(queries):03}',group='development_extra_no_answer',query=template.format(s=s),expected=[]))
for n,s in enumerate(chinese_subjects):
 for template in chinese:queries.append(dict(id=f'dev-extra-zh-{len(queries):03}',group='development_extra_no_answer',query=template.format(s=s),expected=[]))
labels=dict(queries=queries,scope='Additional development negatives cover absent entities/attributes across English/Chinese report, recording, image and medical-question styles. Subjects are absent from the original development sources. Not held-out validation; no frozen input was opened or used by this generator.')
(h/'development-negatives-v2-labels.json').write_text(json.dumps(labels,ensure_ascii=False,indent=2)+'\n')
spec=importlib.util.spec_from_file_location('ipc',h/'measure_batch.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);start=time.monotonic();worker=m.Worker([a.helper.resolve(),a.model.resolve()])
try:
 for q in queries:
  reply,ms=worker.request(dict(texts=['task: search result | query: '+q['query']]))
  assert not reply.get('error'),reply
  q['vector']=reply['embeddings'][0];q['ipc_ms']=ms
 result=dict(**labels,helper_sha256=hashlib.sha256(a.helper.read_bytes()).hexdigest(),model_sha256=hashlib.sha256(a.model.read_bytes()).hexdigest(),wall_seconds=time.monotonic()-start)
 target.write_text(json.dumps(result,ensure_ascii=False)+'\n');print('Captured',len(queries),'development negatives',result['wall_seconds'])
finally:worker.close()
