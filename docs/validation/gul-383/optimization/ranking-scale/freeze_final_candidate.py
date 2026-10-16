#!/usr/bin/env python3
"""Freeze an independent regression set after development selection; no result-driven edits."""
import hashlib, json
from pathlib import Path

h = Path(__file__).parent
target = h / 'rework-final2-labels.json'
assert not target.exists()
# title | factual passage | Chinese title/passage | paraphrase | cross-language paraphrase
facts = '''Ticket Sleeves|Concert tickets are stored in transparent numbered sleeves.|门票归档|音乐会门票存放在透明编号袋内。|How should the concert admission slips be kept?|音乐会入场券应该怎样保存？
Compass Care|Compasses are kept away from magnetic cabinet doors.|罗盘保养|罗盘应远离带磁性的柜门。|What should a navigation compass be separated from?|导航罗盘需要远离什么？
Ceramic Delivery|Pottery deliveries use cork pads between each bowl.|陶器运输|运输陶碗时每只碗之间放置软木垫。|What separates the bowls during a pottery shipment?|运送陶碗时用什么隔开碗？
Roof Access|Roof visitors sign the purple logbook at the stairwell.|屋顶登记|前往屋顶的访客在楼梯间的紫色记录簿上签字。|Where do people visiting the rooftop leave their signature?|去屋顶的访客在哪里签名？
Museum Gloves|Museum volunteers wear cotton gloves when handling medals.|奖章防护|博物馆志愿者拿取奖章时戴棉手套。|What hand protection is used for the museum medals?|拿博物馆奖章时用什么保护双手？
Telescope Covers|Telescope lenses receive fitted caps before the dome closes.|镜头遮盖|天文台穹顶关闭前应给望远镜镜头盖上配套盖子。|What happens to the telescope optics before shutting the dome?|关闭穹顶前望远镜镜头要做什么？
Map Repairs|Torn maps are repaired using reversible archival tape.|地图修补|破损地图使用可移除的档案胶带修补。|Which material mends a damaged map without permanent bonding?|用什么材料修地图又不会永久粘住？
Piano Humidity|Piano rooms keep a shallow water tray beneath the bench.|琴房湿度|钢琴房在琴凳下面放一盘浅水。|Where is the moisture tray in the piano room?|琴房的保湿水盘放在哪里？
Ferry Bicycles|Ferry passengers secure bicycles with the provided green straps.|渡轮单车|渡轮乘客用船上提供的绿色绑带固定自行车。|How are bicycles fastened aboard the ferry?|轮渡上的自行车怎么固定？
Lantern Check|Lantern wicks are trimmed before the evening procession.|灯芯修剪|夜间巡游开始前要修剪灯笼的灯芯。|What preparation is required for lantern wicks before the march?|游行前灯笼灯芯需要怎样处理？
Specimen Labels|Shell specimens receive pencil labels rather than ink marks.|贝壳标注|贝壳标本用铅笔标签而不是墨水做标记。|How are collected shells labeled for the specimen archive?|收藏的贝壳标本用什么标注？
Sail Folding|Dry sails are folded along their stitched diagonal seams.|船帆折叠|干燥的船帆沿缝制的对角接缝折叠。|Which lines guide the folding of a dry sail?|干船帆沿什么线折叠？
Stamp Viewing|Visitors inspect rare stamps through mounted magnifying lenses.|邮票观赏|访客通过固定的放大镜观看珍贵邮票。|What helps visitors examine tiny details on valuable stamps?|看珍贵邮票的细节要用什么？
Clay Storage|Unused sculpting clay is wrapped in damp linen overnight.|陶泥保存|未使用的雕塑陶泥过夜时用湿亚麻布包裹。|How is leftover sculpting material protected until morning?|剩下的雕塑陶泥如何保存到第二天？
Costume Hooks|Stage costumes hang on broad wooden hooks after rehearsal.|戏服悬挂|排练后戏服挂在宽大的木钩上。|Where are theater outfits placed once practice ends?|排练结束后戏服放在哪里？
Aqueduct Walk|Aqueduct tours begin beside the western stone arch.|水渠导览|古水渠参观从西侧石拱门旁开始。|Where does the guided aqueduct visit start?|水渠导览从什么地方出发？
Paper Drying|Handmade paper dries on mesh shelves above the sink.|纸张晾干|手工纸放在水槽上方的网架上晾干。|Where is newly made paper left to lose its moisture?|新做的纸放在哪里晾干？
Marble Transport|Sculpted marbles travel inside padded cylindrical cases.|石雕包装|大理石雕件装在带衬垫的圆筒盒内运输。|What container protects marble sculptures in transit?|运输大理石雕件用什么容器？
Bell Practice|Bell ringers practice with felt dampers fitted to the clappers.|钟锤消音|敲钟练习时钟锤上安装毛毡消音垫。|How is the bell muted during ringing practice?|练习敲钟时怎样降低声音？
Loom Threads|Loom operators tie broken threads with a small weavers knot.|织线接续|织机操作员用小织工结接好断线。|How is a snapped thread rejoined on the loom?|织机上的断线怎样接起来？
Harbor Flags|Harbor signal flags are lowered before the lighthouse lamp starts.|港口旗帜|灯塔亮灯之前降下港口信号旗。|When are harbor signaling flags brought down?|港口信号旗什么时候降下来？
Wool Inspection|Wool inspectors spread each fleece on a slatted inspection table.|羊毛检查|检验员把每张羊毛铺在板条检查台上。|Where is a fleece spread out for examination?|检查羊毛时将它铺在哪里？
Chess Pieces|Tournament chess pieces are counted into velvet bags after play.|棋子收纳|比赛结束后清点棋子并放入天鹅绒袋内。|How are the chessmen put away once a tournament game ends?|棋赛结束后怎样收好棋子？
Glass Etching|Glass engravers trace patterns with removable wax pencils.|玻璃描样|玻璃雕刻师使用可擦除的蜡笔描绘图案。|Which drawing tool marks the pattern before glass engraving?|雕刻玻璃之前用什么描图？
Trail Stones|Trail keepers repaint the white marks on boundary stones each spring.|界石维护|步道管理员每年春天重新涂刷界石上的白色标记。|What seasonal upkeep do the trail boundary markers receive?|步道界石每年要做什么维护？'''
negatives = [
    'Who wrote the first opera performed on Venus?', 'Where is the entrance to the invisible cathedral?',
    'How fast can a silver-winged unicorn run?', 'What does the vanished city of Qemor export?',
    'Which alphabet is used by the crystal birds?', 'When does the silent comet return?',
    'How deep is the imaginary sea of amber?', 'Who governs the floating kingdom of Thessa?',
    'What powers the clockwork sun?', 'Which language do the mountain giants speak?',
    'How many branches does the legendary sky tree have?', 'Where was the first mirror dragon born?',
    'What is the mass of the transparent mountain?', 'Who designed the bridge between dreams?',
    'How long does a moonflower made of steel live?', 'Which direction does the enchanted river flow?',
    'What is the currency of the forgotten cloud republic?', 'Who named the island beneath the stars?',
    'How high is the tower in the invisible forest?', 'Where do the whispering snow lions sleep?',
    'What fuels the emerald submarine of myth?', 'Which constellation contains the city of golden dust?',
    'Who composed the anthem of the glass kingdom?', 'How does the legendary feather engine start?',
    'Where is the capital of the paper universe?'
]
documents, queries = [], []
colors = ['red', 'blue', 'green', 'yellow', 'black']; shapes = ['square', 'rectangle', 'ellipse', 'pentagon', 'hexagon']
for i, line in enumerate(facts.splitlines()):
    title, text, zhTitle, zh, para, cross = line.split('|')
    en, cn, audio, image = [f'final2-{kind}-{i:02}' for kind in ['en', 'zh', 'audio', 'image']]
    color, shape = colors[i//5], shapes[i%5]
    documents.extend([dict(id=en,kind='text',text=f'{title}. {text} Reference NQ-{6200+i}.'),
                      dict(id=cn,kind='text',text=zhTitle+'。'+zh),dict(id=audio,kind='audio',text=text),
                      dict(id=f'final2-foil-{i:02}',kind='text',text=f'Catalog entry {i}. Administrative records describe a stored object with an assigned location, responsible keeper and scheduled inspection. The label is teal and the shelf is wooden.'),
                      dict(id=image,kind='image',text='',color=color,shape=shape)])
    for group, query, expected in [('lexical',text,[en]),('identifier_unicode',f'ＮＱ－{6200+i}',[en]),
                                   ('chinese_short',zhTitle,[cn]),('cross_language',cross,[en]),
                                   ('semantic_paraphrase',para,[en]),('audio_semantic','audio recording: '+para,[audio]),
                                   ('image_semantic',f'image of a {color} {shape} on white paper',[image]),
                                   ('no_answer',negatives[i],[])]:
        queries.append(dict(id=f'final2-{group}-{i:02}',group=group,query=query,expected=expected))
result = dict(version=1,provenance='Frozen after development-abstention-trials-v6 selection. '
              'Independent fictional operational topics and generated media; not representative user relevance. '
              'Original three 200-query holdouts remain separate regressions. No tuning on this fixture.',
              documents=documents,queries=queries)
target.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(len(documents),len(queries),hashlib.sha256(target.read_bytes()).hexdigest())
