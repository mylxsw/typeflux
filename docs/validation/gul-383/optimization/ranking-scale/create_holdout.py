#!/usr/bin/env python3
"""Freeze new query wording after the initial oracle exposed an English-to-Chinese ranking failure."""
import importlib.util, json
from pathlib import Path

root=Path(__file__).resolve().parents[5]
spec=importlib.util.spec_from_file_location('topics',root/'scripts/create_semantic_query_fixture.py')
topics=importlib.util.module_from_spec(spec);spec.loader.exec_module(topics)
EN=[
'What evidence and sign-off are needed to recover business spending?',
'How often should tomatoes receive water?',
'Is a sleeper train seat booking required before getting on?',
'Where should protected duplicate data be stored?',
'Where can a new employee pick up their computer?',
'At what hours is the midday meal available?',
'Which channel and ticket class should employees use for trips?',
'How should everyone evacuate and where should they gather?',
'Which container takes unsoiled sheets of paper?',
'Where may staff leave their bikes?',
'How long can someone keep a borrowed book?',
'Which space should a group book for discussions?',
'On which working day does employee pay arrive?',
'How far ahead should paid time off be requested?',
'Where should a package awaiting collection be left?',
'How should preliminary documents be printed to save paper?',
'How do guests get short term internet access?',
'Who receives reports of damaged apparatus?',
'What must a driver do before using the indoor car park?',
'What is required before someone is allowed inside the lab?',
'What morning task keeps the kitchen drinks machine supplied?',
'What identification is required to enter an exhibition?',
'What order document accompanies a billing request?',
'What inventory step is required before relocating stock?',
'Who must approve agreements with vendors?',
]
ZH=[
'员工想拿回垫付的项目费用，要准备什么并由谁同意？',
'番茄苗多久需要补一次水？',
'上夜行火车之前是否要先留座？',
'加密的数据副本应该放在哪里？',
'新同事去哪儿拿工作用的电脑？',
'中饭在几点之间供应？',
'出差订机票应该选什么舱位，在哪里订？',
'遇到火警应该走哪条路，最后在哪里集合？',
'没有污渍的废纸该丢进哪种颜色的桶？',
'骑来的单车放在什么地方？',
'借阅书籍多少天内需要送回？',
'多人讨论该提前订哪个房间？',
'每个月哪一天能收到薪水？',
'申请带薪年假需要提前多久？',
'等候寄送的包裹应该放在哪里？',
'文件初稿怎样印才节约纸张？',
'来访人员如何取得临时联网凭证？',
'仪器坏了该找哪个服务部门？',
'开车进地下车场之前要登记什么？',
'想进入实验室，得先学完什么？',
'每天早上要为厨房的饮品机器添什么？',
'进入展览现场需要出示什么证件？',
'申请开具账单时应该附带哪张采购单据？',
'挪动库里的货物之前得先扫什么？',
'与供货商签的协议必须由谁审阅？',
]
NO_ANSWER=[
'How do dragons obtain licenses for teleportation?',
'Does the lunar embassy accept crystal currency?',
'Where can a mermaid recharge a flying chariot?',
'How many feathers are needed to steer a comet?',
'What language do invisible nebula creatures speak?',
'Can a wizard turn moonlight into edible diamonds?',
'Which spell reverses the direction of gravity?',
'Where is the portal to the underwater kingdom?',
'How is a phoenix hatched inside a neutron star?',
'Who invented time travel for ancient dinosaurs?',
'What fuel powers a spaceship made of starlight?',
'How can a ghost unlock a parallel universe?',
'Are enchanted asteroids allergic to silver dust?',
'How are unicorn dreams transmitted to distant galaxies?',
'Which potion lets a jellyfish breathe in vacuum?',
'Why do imaginary planets orbit a square sun?',
'Can talking mountains predict the colour of tomorrow?',
'Where are the invisible wings of a cosmic serpent?',
'How does a sorcerer bottle the sound of thunder?',
'What is the mass of a fictional antimatter dragon?',
'How many moons fit inside a magical teacup?',
'Which mythical ocean contains liquid rainbows?',
'How does a centaur repair a broken time machine?',
'What password opens the dream dimension?',
'How do extraterrestrial fairies manufacture dark matter?',
]
queries=[]
for i,(_,zh,fact,zhfact) in enumerate(topics.TOPICS):
    enid,zhid=f'en-{i:02}',f'zh-{i:02}'
    code=f'TS-{9000+i}'
    wide=''.join(chr(ord(c)+0xfee0) if 0x21<=ord(c)<=0x7e else c for c in code)
    cases=[('english_semantic',EN[i],[enid],fact),('chinese_semantic',ZH[i],[zhid],zhfact),
           ('english_to_chinese',EN[i],[zhid],zhfact),('chinese_to_english',ZH[i],[enid],fact),
           ('identifier_unicode',wide,[enid],code),('phrase','"'+fact.rstrip('.')+'"',[enid],fact),
           ('chinese_short',zh+'？',[zhid],zhfact),
           ('no_answer',NO_ANSWER[i],[],None)]
    for g,q,expected,anchor in cases:
        queries.append(dict(id=f'holdout_{g}-{i:02}',group=g,query=q,expected=expected,anchor=anchor))
out=Path(__file__).parent/'holdout-queries.json'
out.write_text(json.dumps(dict(version=1,provenance='50 new hand-authored semantic questions plus derived exact/Unicode/short/no-answer cases. Frozen after initial 200-query calibration diagnosis. Query wording held out; source facts and documents are shared. Synthetic, single-author labels; not a representative corpus.',queries=queries),ensure_ascii=False,indent=2)+'\n')
print(f'Frozen {len(queries)} queries')
