#!/usr/bin/env python3
"""Freeze once after actual Swift development replay; never edit labels from observed results."""
import hashlib,json
from pathlib import Path
h=Path(__file__).parent;target=h/'rework-final3-labels.json'
assert not target.exists()
assert (h/'ranking-coverage-development-v9-development-v9.json').is_file()
facts='''Seed packets|Seed packets are sorted into tin boxes by harvest season.|种袋分类|种子袋按收获季节放入铁盒分类。|How are the seed envelopes organized for storage?|种子包装按照什么分类存放？
Rain barrels|Rain barrels are covered with mesh to keep fallen leaves out.|雨桶防护|储雨桶用网布盖住以防落叶进入。|What stops leaves from falling into the rainwater containers?|怎样避免落叶进入储雨的桶？
Volunteer keys|Volunteer keys are collected from a hook behind the reception desk.|义工钥匙|义工从接待台后方的挂钩领取钥匙。|Where can volunteers pick up their keys?|义工到哪里领取钥匙？
Bench repairs|Loose bench slats are marked with chalk before maintenance begins.|长椅维修|维修前用粉笔标记长椅上松动的板条。|How are unstable strips on the benches identified for repair?|如何标记长椅上需要修理的松动木条？
Greenhouse shoes|Visitors exchange outdoor shoes for washable slippers at the greenhouse door.|温室换鞋|访客在温室门口把外鞋换成可清洗的拖鞋。|What footwear do visitors put on before entering the plant house?|进入温室之前访客要换什么鞋？
Market tokens|Unused market tokens are returned to the wooden tray beside the exit.|市集筹码|未使用的市集筹码放回出口旁的木托盘。|Where should leftover tokens be placed when leaving the market?|离开市集时剩余筹码放在哪里？
Bicycle pumps|Bicycle pumps are attached to the repair stand with braided cables.|气筒固定|自行车打气筒用编织钢缆连接在修车架上。|How are the tire pumps secured to the maintenance station?|自行车气筒怎样固定在维修站？
Bee water|Bee watering dishes contain pebbles so insects can land safely.|蜜蜂饮水|蜜蜂饮水碟内放入小卵石方便昆虫安全停留。|Why are small stones put in the drinking dishes for bees?|蜜蜂的水碟里为什么放小石头？
Donation labels|Donation boxes receive dated paper labels before entering the sorting room.|捐箱标签|捐赠箱进入分拣室前贴上写有日期的纸标签。|What identification is added to donated boxes before sorting?|捐赠箱分拣之前需要贴什么标签？
Workshop towels|Damp workshop towels are hung on the outdoor rail before closing.|工坊毛巾|关门前将工坊的湿毛巾挂到室外栏杆上。|Where are wet cloths left to dry at the end of workshop hours?|工坊关门时湿毛巾挂在哪里？
Library returns|Library returns are placed spine upward in the blue rolling cart.|还书摆放|图书馆归还的书书脊向上放在蓝色推车里。|How should returned books be arranged in the movable cart?|归还的图书怎样摆在推车内？
Candle molds|Candle molds are cooled on stone tiles before the wax is removed.|烛模冷却|蜡烛模具放在石砖上冷却后再脱模。|Where do the molds rest while cooling before candle removal?|蜡烛脱模之前模具放在哪里冷却？
Community notices|Community notices are pinned below the clock in the entrance hall.|社告张贴|社区通知贴在入口大厅时钟下方。|Where can visitors read the neighborhood announcements?|来访者在哪里查看社区公告？
Fruit baskets|Empty fruit baskets are stacked upside down beneath the packing table.|果篮收纳|空果篮倒扣叠放在包装台下方。|How are unused produce baskets stored under the work table?|不用的水果篮如何收在工作台下面？
Walking poles|Walking poles are grouped in pairs using reusable fabric loops.|手杖配对|徒步手杖用可重复使用的布环两根一组固定。|What keeps each pair of hiking poles together?|用什么把一对登山手杖绑在一起？
Puzzle sets|Finished puzzle sets are counted and sealed inside clear zipper pouches.|拼图收好|拼图玩完后清点并封进透明拉链袋。|How are jigsaw pieces packed after checking that the set is complete?|拼图清点齐全后怎样包装？
Bird feeders|Bird feeders are rinsed with plain water before fresh grain is added.|鸟台清洁|添加新谷物之前先用清水冲洗喂鸟器。|What is done to the feeding stations before refilling the grain?|补充鸟食之前怎样处理喂食器？
Stage cables|Stage cables follow the wall edge and are held down with cloth tape.|舞线固定|舞台电缆沿墙边铺设并用布胶带固定。|Where are performance cables routed and how are they secured?|演出电缆沿哪里铺设并怎样固定？
Coffee grounds|Used coffee grounds are placed in the brown collection bucket beside the sink.|咖渣收集|用过的咖啡渣放在水槽旁的棕色收集桶。|Where should the residue from brewing coffee be discarded?|冲泡咖啡剩下的渣放在哪里？
Repair receipts|Repair receipts are filed in order of collection date rather than customer name.|维修收据|维修收据按照取件日期而不是顾客姓名归档。|Which order is used to organize the repair paperwork?|维修凭据按什么顺序归档？
Marsh boots|Marsh boots are brushed outside before being placed on the drying rack.|湿地靴清理|湿地靴先在室外刷净再放上晾架。|What cleaning happens before muddy field boots go on the rack?|沾泥的野外靴上晾架前怎样清理？
Lunch containers|Reusable lunch containers are stored with lids separate to allow air circulation.|餐盒通风|可重复使用的餐盒存放时盒盖分开放以便通风。|How are food boxes stored so air can circulate inside them?|怎样存放饭盒以保持内部通风？
Ticket queue|The ticket queue begins at the painted yellow footprint near the gate.|票队起点|售票队伍从大门附近画出的黄色脚印处开始。|Which floor mark indicates where the admission line starts?|地上什么标记表示购票队伍起点？
Watering rounds|Morning watering rounds start with the shaded beds beside the north wall.|浇水顺序|早晨浇水从北墙旁阴凉的花圃开始。|Which garden beds are watered first in the morning?|早上先给哪片花圃浇水？
Loan umbrellas|Loan umbrellas are dried open in the covered courtyard before returning to storage.|借伞晾干|借出的雨伞撑开放在带顶庭院晾干后再入库。|Where and in what position are borrowed umbrellas dried?|借用的伞在哪里以什么姿态晾干？'''
negatives=['Which alloy is used by the fictional shadow elevator?','Who signed the charter of the imaginary moss republic?','Where does a mythical stone whale recharge?','What is the age of the invisible orchard?','Which station sells tickets to the sleeping planet?','How does the legendary paper submarine navigate?','What language is printed on the lost amber crown?','Who maintains the bridge inside the moon?','Where are the wings of the imaginary brass fox kept?','What powers the engine in the city of mist?','Which number identifies the fictional snow palace?','How are parcels delivered to the kingdom of clouds?','What is the recipe for the mythical glass bread?','Who drew the map of the underwater desert?','When does the clock in the transparent castle strike?','Where was the imaginary copper dragon hatched?','Which currency buys memories in the dream harbor?','How many floors are in the mythical feather tower?','What song opens the gate to the silver forest?','Which constellation hosts the invisible post office?','Who built the train across the imaginary ocean of stars?','What is the address of the forgotten mirror kingdom?','How does the legendary marble bird breathe?','Which alphabet is carved on the fictional sun key?','Where does the mythical river of lanterns end?']
documents=[];queries=[];colors=['red','blue','green','yellow','black'];shapes=['circle','triangle','diamond','star','cross']
for i,line in enumerate(facts.splitlines()):
 title,text,zhTitle,zh,para,cross=line.split('|');en,cn,audio,image=[f'final3-{kind}-{i:02}' for kind in ['en','zh','audio','image']]
 color,shape=colors[i//5],shapes[i%5]
 documents.extend([dict(id=en,kind='text',text=f'{title}. {text} Reference VX-{8100+i}.'),dict(id=cn,kind='text',text=zhTitle+'。'+zh),dict(id=audio,kind='audio',text=text),dict(id=f'final3-foil-{i:02}',kind='text',text=f'Office register {i}. Routine administrative entries describe responsibilities, planned visits and storage locations. Items are checked using the normal register. Record status: current.'),dict(id=image,kind='image',text='',color=color,shape=shape)])
 for group,query,expected in [('lexical',text,[en]),('identifier_unicode',f'ＶＸ－{8100+i}',[en]),('chinese_short',zhTitle,[cn]),('cross_language',cross,[en]),('semantic_paraphrase',para,[en]),('audio_semantic','audio recording: '+para,[audio]),('image_semantic',f'image of a {color} {shape} on white paper',[image]),('no_answer',negatives[i],[])]:queries.append(dict(id=f'final3-{group}-{i:02}',group=group,query=query,expected=expected))
result=dict(version=1,provenance='Frozen after development-v9 policy and actual Swift development replay. Independent synthetic operational facts and generated media. All four previous200-query holdouts remain separate, including their failures. No tuning on these labels. Shared simple shape renderer is a controlled visual test, not representative photography.',documents=documents,queries=queries)
target.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');print(len(documents),len(queries),hashlib.sha256(target.read_bytes()).hexdigest())
