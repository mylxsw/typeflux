#!/usr/bin/env python3
"""Freeze and capture a query-only holdout after the script/modality correction; never tune from it."""
import argparse,hashlib,importlib.util,json
from pathlib import Path
EN=[
'Where do I pick up a ticket for the guided museum visit?',
'Can spectators get into the hall thirty minutes before the performance?',
'Which container beside the changing area is for damp towels?',
'At which hour does the campsite require silence?',
'Where should I go after eight to collect bread that I ordered?',
'What terminal do researchers use to sign in?',
'If the sky is overcast, which indoor venue hosts the activity?',
'How does a group arrange permission to visit the greenhouse?',
'Where do island travellers board their vessel?',
'Must a returned game have all of its original components?',
'On what morning do first-time shelter volunteers receive their introduction?',
'Which cupboard contains the eye protection for the workshop?',
'Is next Tuesday the collection day for finished pottery?',
'What facility takes bulky luggage before the concert?',
'Where near the fountain are recovered belongings stored?',
'Who lends a camera support stand on club evenings?',
'What colour signs show the path to the lakeside rest shelter?',
'Where should the hand tools go once a makerspace session is over?',
'Is the member website updated with the talk recording the following morning?',
'Who gives out tokens for the players storage cupboards?',
'Does the craft show form need three pictures of the proposed work?',
'Which rack holds paddles that have already been reserved?',
'On which weekday does the noticeboard get its new telescope timetable?',
'What description must I attach when dropping off a faulty item?',
'Are the singers rehearsing in the western hall on Thursday nights?',
]
ZH=[
'博物馆带讲解的参观票应该到哪一个售票亭拿？',
'观众厅是不是提前三十分钟让大家进去？',
'更衣区域边上哪个容器用来收湿毛巾？',
'露营区要求从晚上哪个时刻开始不再喧闹？',
'早上八点以后，预先订的面包应该去哪个台子取？',
'研究者用接待处的什么设备办理来访登记？',
'阴天看不了星空时，活动安排在哪个室内场所？',
'团体想参观玻璃花房，应当如何提前联系？',
'去海岛的旅客需要从几号码头登船？',
'桌面游戏还回去的时候，是否要确保零件都在？',
'第一次来帮忙的动物收容志愿者哪天上午接受介绍？',
'工坊提供的眼部防护用品放在入口附近哪里？',
'下个星期二能不能领取已经烧好的作品？',
'进入音乐会场前，体积大的行李应交给哪个地方保管？',
'喷泉附近哪里负责保存捡到的东西？',
'摄影社活动晚上，从哪个服务台借相机的支撑架？',
'想走到湖边歇脚的亭子，应寻找哪种颜色的路标？',
'创客活动结束，使用过的手工具要归放到哪儿？',
'会员网页是不是在讲座后的次日早晨提供录像？',
'想使用运动场馆的储物柜，要从哪里取得代币？',
'报名手工展示活动，申请单是否必须附三张作品图？',
'已经预约的划船用桨摆在办公室边上的哪个架子？',
'每周哪天能在公告板看到最新的观星器材活动表？',
'把坏掉的物件交给受理人员之前，纸上应该写什么？',
'星期四夜里的合唱练习安排在西边的大厅吗？',
]
NO_ANSWER=[
'How do ribosomes distinguish the start codon during translation?',
'Why does a quartz oscillator exhibit piezoelectric resonance?',
'How is a Byzantine fault tolerant consensus protocol proved correct?',
'What separates the Cambrian sedimentary layers from older rock?',
'How do archaeologists identify trade routes from ceramic isotopes?',
'What is the mechanism of nitrogen fixation in root nodules?',
'Why does the strong nuclear force have a short effective range?',
'How are paleolithic stone blade manufacturing sites classified?',
'What causes a semiconductor junction to emit coherent light?',
'How do linguists infer the stress patterns of a lost language?',
'Why can a Bose Einstein condensate show macroscopic interference?',
'How does a bacterial flagellum convert a proton gradient into rotation?',
'What explains the anomalous thermal expansion of some crystal lattices?',
'How is a graph automorphism group computed efficiently?',
'Which methods recover the structure of a membrane protein?',
'How do historians date an unsigned medieval manuscript?',
'What is the role of a catalyst in an asymmetric hydrogenation reaction?',
'Why do tectonic plates sometimes show slow slip without a major quake?',
'How is the chirality of an organic molecule determined spectroscopically?',
'What caused the diversification of ancient trilobite species?',
'How does a compiler prove that a loop invariant can be moved?',
'What determines the absorption lines of interstellar molecular clouds?',
'How do geochemists estimate the age of a zircon crystal?',
'Why can quantum error correction tolerate correlated phase noise?',
'How are reconstructed ancestral gene sequences validated?',
]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--helper',type=Path,required=True);p.add_argument('--model',type=Path,required=True)
a=p.parse_args();here=Path(__file__).parent
base=json.loads((here/'final-holdout-labels.json').read_text());vectors=json.loads((here/'final-holdout-vectors.json').read_text())
queries=[]
for i in range(25):
 en,zh,audio=f'final-en-{i:02}',f'final-zh-{i:02}',f'final-audio-{i:02}'
 edoc=next(d for d in base['documents'] if d['id']==en);zdoc=next(d for d in base['documents'] if d['id']==zh)
 title=edoc['text'].split('.')[0];short=zdoc['text'].split('说明')[0]
 image=next(d for d in base['documents'][i*4:i*4+4] if d['kind']=='image')
 cases=[('lexical',title+' '+edoc['text'].split('.')[1].strip().split()[0],[en]),
        ('identifier_unicode',f'Find (VH-{7300+i}), please',[en]),
        ('chinese_short','关于'+short+'的说明',[zh]),
        ('cross_language',EN[i] if i%2 else ZH[i],[zh if i%2 else en]),
        ('semantic_paraphrase',ZH[i] if i%2 else EN[i],[zh if i%2 else en]),
        ('audio_semantic','audio about: '+EN[i],[audio]),
        ('image_semantic','image showing a '+image['color']+' '+image['shape'],[image['id']]),
        ('no_answer',NO_ANSWER[i],[])]
 for group,text,expected in cases:queries.append(dict(id=f'unseen_{group}-{i:02}',group=group,query=text,expected=expected))
labels=dict(version=1,queries=queries,source_labels_sha256=hashlib.sha256((here/'final-holdout-labels.json').read_bytes()).hexdigest(),scope='New query wording over the fixed retrieval corpus, frozen after script/modality calibration code was fixed. No result from these queries is used to select parameters. Earlier source-level holdout failure remains in the evidence.')
(here/'unseen-query-labels.json').write_text(json.dumps(labels,ensure_ascii=False,indent=2)+'\n')
spec=importlib.util.spec_from_file_location('worker',here/'measure_batch.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
w=m.Worker([a.helper.resolve(),a.model.resolve()])
try:
 for q in queries:
  reply,_=w.request(dict(texts=['task: search result | query: '+q['query']]));assert not reply.get('error'),reply
  q['vector']=reply['embeddings'][0]
 result=dict(documents=vectors['documents'],queries=queries,labels_sha256=hashlib.sha256((here/'unseen-query-labels.json').read_bytes()).hexdigest(),model_sha256=vectors['model_sha256'],projector_sha256=vectors['projector_sha256'],scope=labels['scope'])
 (here/'unseen-query-vectors.json').write_text(json.dumps(result,ensure_ascii=False)+'\n')
 print('Captured',len(queries),'unseen query vectors')
finally:w.close()
