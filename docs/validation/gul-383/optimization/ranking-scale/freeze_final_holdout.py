#!/usr/bin/env python3
"""Freeze independent source documents, synthetic media and query labels before final evaluation."""
import json
from pathlib import Path
FACTS=[
('museum tour','导览','Collect guided-tour tickets at the north kiosk.','导览票在北侧售票亭领取。','Where are tickets for a guided visit picked up?','参观讲解活动的票在哪里领？'),
('theatre entry','剧院','The auditorium doors open half an hour before the performance.','演出开始前半小时开放观众厅。','How early can the audience enter before the show?','观众在演出前多久能够入场？'),
('pool towels','泳池','Return used towels to the basket beside the changing rooms.','用过的毛巾放回更衣室旁的篮子。','Where should swimmers leave their used towels?','游泳后用过的毛巾放在哪儿？'),
('campground quiet','营地','Quiet hours begin at ten in the evening.','夜间安静时间从晚上十点开始。','When must campers stop making noise?','露营者晚上几点以后应保持安静？'),
('bakery collection','面包','Collect reserved loaves from the side counter after eight in the morning.','预订的面包在早上八点后到侧柜台领取。','When and where can a reserved loaf be collected?','订好的面包什么时候在哪个柜台取？'),
('archive access','档案','Researchers register their visit at the reception terminal.','研究人员须在接待处终端登记来访。','How do visitors register to consult the records?','查阅资料的研究人员在哪儿登记？'),
('observatory weather','天文台','Cloudy-night sessions are moved to the indoor planetarium.','多云夜晚的活动改在室内星象馆进行。','Where does the session go when clouds prevent observation?','天上云多无法观测时，活动改到哪里？'),
('greenhouse visits','温室','Group visits require advance booking through the garden office.','团体参观须提前向园区办公室预约。','Who handles advance reservations for groups?','多人一起参观需要提前向谁预约？'),
('ferry boarding','渡轮','Passengers board the island ferry from pier four.','前往海岛的乘客从四号码头上船。','Which pier is used for the boat to the island?','去岛上的船在哪个码头上？'),
('boardgame loans','桌游','Borrowed games must include every piece when returned.','归还借用的游戏时必须包含全部配件。','What must be checked before a borrowed game is returned?','归还借来的游戏前需要确认什么？'),
('shelter orientation','收容所','New volunteers attend orientation on Saturday mornings.','新志愿者在周六上午参加入门说明会。','When do new helpers attend their first orientation?','新加入的志愿者什么时候参加说明会？'),
('workshop equipment','工坊','Safety goggles are stored in the cabinet beside the entrance.','护目镜存放在入口旁的柜子中。','Where can workshop users find protective goggles?','使用工坊的人在哪里拿护目镜？'),
('ceramics collection','陶艺','Finished pottery can be collected on the following Tuesday.','烧制完成的陶器可在下一周二领取。','On which day can the completed pottery be picked up?','做完烧好的陶器可以在哪一天取？'),
('concert bags','演唱会','Large bags are checked at the cloakroom before entry.','大件行李须在入场前寄存在衣帽间。','Where should concertgoers leave a large bag?','看演出时大包应该寄存在哪里？'),
('market lost property','集市','Lost items are kept at the information booth near the fountain.','失物保管在喷泉旁的咨询亭。','Where are items found at the market held?','在集市遗失的东西要去哪里找？'),
('photo club equipment','摄影','Tripods can be borrowed from the equipment desk on club nights.','社团活动当晚可在器材台借用三脚架。','Where can members borrow a tripod during the meeting?','社团活动时，成员在哪里借三脚架？'),
('woodland route','林间步道','Follow the orange markers to reach the lakeside shelter.','沿橙色标记行走可抵达湖边休息亭。','Which trail markings lead to the shelter by the lake?','去湖边休息亭应该沿什么颜色的标记走？'),
('makerspace tools','创客空间','Return hand tools to the numbered slots after each session.','每次活动后将手工具放回对应编号的槽位。','How should hand tools be put away after use?','活动结束后手工具应该怎样收好？'),
('lecture recordings','讲座','Recordings appear in the member portal the next morning.','录播会在次日早上发布到会员门户。','When and where can members watch a recorded talk?','会员什么时候在哪儿看到讲座录播？'),
('sports lockers','球馆','Locker tokens are available from the front desk.','储物柜代币可向前台领取。','Where can players get a token for a locker?','运动的人去哪里领取储物柜代币？'),
('craft exhibition','手工展','Applicants submit three photos of their work with the entry form.','参展申请表须附上三张作品照片。','How many pictures accompany an exhibition application?','申请参加展览时要随表格附几张作品照片？'),
('boathouse collection','船屋','Reserved paddles are collected from the rack beside the office.','预订的船桨在办公室旁的架子上领取。','Where are reserved paddles picked up?','订好的船桨在哪里拿？'),
('astronomy club meetings','星空社','The telescope session list is posted on the noticeboard every Monday.','每周一在公告栏张贴望远镜活动安排。','Where and when is the telescope schedule posted?','望远镜活动安排什么时候贴在哪里？'),
('repair cafe intake','维修站','Attach a description of the fault before leaving an item at the intake desk.','把物品留在受理台前应附上故障说明。','What information should accompany an item left for repair?','把东西交给维修受理台时，需要附上什么说明？'),
('community choir practice','合唱团','Rehearsals take place in the west hall on Thursday evenings.','排练在周四晚上于西厅举行。','Where and when does the choir rehearse?','合唱排练在什么时间哪个厅举行？')]
NO_ANSWER=[
'How does photosynthesis regulate carbon fixation in ocean algae?',
'What causes magnetic reconnection in a solar flare?',
'Which enzymes copy the genetic material of a bacteriophage?',
'How are the phonemes of an extinct language reconstructed?',
'What explains the precession of a rotating neutron star?',
'How does plate subduction create an island arc?',
'Why does superfluid helium flow without measurable viscosity?',
'What are the distinguishing features of Etruscan grammar?',
'How is the spectrum of a distant exoplanet measured?',
'What causes the resistance transition in a superconductor?',
'How did medieval scribes prepare their vellum sheets?',
'Which mechanism produces a volcanic lightning discharge?',
'Why do some enzymes follow cooperative binding kinetics?',
'How does a compiler construct its static single assignment graph?',
'What is the proof of the prime number theorem?',
'How does a radio telescope correct for ionospheric distortion?',
'Which pigments were used in ancient cave paintings?',
'Why does a gravitational lens produce multiple apparent images?',
'How is a protein folding pathway experimentally inferred?',
'What are the defining properties of a quasicrystal?',
'How does a coral symbiont respond to rising seawater temperature?',
'What produced the earliest surviving cuneiform inscriptions?',
'How does an error correcting code detect a burst of bit flips?',
'What is the relationship between entropy and reversible computation?',
'How are the layers of an Antarctic ice core dated?']
COLORS=['red','blue','green','yellow','black'];SHAPES=['circle','triangle','diamond','star','cross']
documents=[];queries=[]
for i,(en,zh,fact,zhfact,qe,qz) in enumerate(FACTS):
 eid,zid,aid=f'final-en-{i:02}',f'final-zh-{i:02}',f'final-audio-{i:02}'
 code=f'VH-{7300+i}'
 documents.extend([dict(id=eid,kind='text',text=f'{en.title()}. {fact} Reference {code}.'),dict(id=zid,kind='text',text=f'{zh}说明。{zhfact}'),dict(id=aid,kind='audio',text=fact)])
 image='final-image-'+COLORS[i//5]+'-'+SHAPES[i%5]
 documents.append(dict(id=image,kind='image',text=COLORS[i//5]+' '+SHAPES[i%5],color=COLORS[i//5],shape=SHAPES[i%5]))
 wide=''.join(chr(ord(c)+0xfee0) if 0x21<=ord(c)<=0x7e else c for c in code)
 cases=[('lexical',en,[eid]),('identifier_unicode',wide,[eid]),('chinese_short',zh,[zid]),
        ('cross_language',qe if i%2 else qz,[zid if i%2 else eid]),
        ('semantic_paraphrase',qz if i%2 else qe,[zid if i%2 else eid]),
        ('audio_semantic','audio recording: '+qe,[aid]),
        ('image_semantic','a photo of a '+COLORS[i//5]+' '+SHAPES[i%5],[image]),
        ('no_answer',NO_ANSWER[i],[])]
 for group,query,expected in cases:queries.append(dict(id=f'final_{group}-{i:02}',group=group,query=query,expected=expected))
target=Path(__file__).parent/'final-holdout-labels.json'
target.write_text(json.dumps(dict(version=1,provenance='Independent fictional source facts, bilingual questions, generated one-segment speech and colour/shape images, plus unrelated science/history questions. Frozen before final inference. Original and revised earlier query sets are development diagnostics after their observed failures; this set is not used for tuning. Synthetic single-author labels, not a representative user-corpus guarantee.',documents=documents,queries=queries),ensure_ascii=False,indent=2)+'\n')
print('Frozen',len(documents),'sources and',len(queries),'queries')
