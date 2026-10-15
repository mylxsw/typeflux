#!/usr/bin/env python3
"""Rebuild the synthetic, source-addressable bilingual regression oracle (no user data)."""
import json
from pathlib import Path

TOPICS = [
    ("reimbursement", "报销", "Attach receipts and obtain manager approval.", "附上发票并获得主管批准。"),
    ("gardening", "园艺", "Water tomato plants twice weekly.", "每周给番茄浇水两次。"),
    ("railway", "铁路", "Reserve a seat before boarding the overnight train.", "乘坐夜间列车前请预订座位。"),
    ("backup", "备份", "Keep encrypted copies on a separate disk.", "在独立磁盘上保存加密副本。"),
    ("onboarding", "入职", "Collect the laptop from the reception desk.", "从前台领取笔记本电脑。"),
    ("cafeteria", "食堂", "Lunch is served between noon and two.", "午餐供应时间为中午十二点到两点。"),
    ("travel", "差旅", "Book economy tickets through the travel portal.", "通过差旅门户预订经济舱机票。"),
    ("fire", "消防", "Use the stairs and assemble outside the east gate.", "走楼梯撤离并在东门外集合。"),
    ("recycling", "回收", "Put clean paper in the blue bin.", "将干净纸张放入蓝色垃圾桶。"),
    ("bicycle", "自行车", "Store bicycles in the basement parking area.", "将自行车停放在地下停车区。"),
    ("library", "图书", "Return borrowed books within twenty days.", "请在二十天内归还借阅的图书。"),
    ("meeting", "会议", "Reserve the large room for group discussions.", "集体讨论请预订大会议室。"),
    ("payroll", "工资", "Salaries arrive on the last business day.", "工资于最后一个工作日到账。"),
    ("vacation", "休假", "Request annual leave two weeks ahead.", "请提前两周申请年假。"),
    ("shipping", "快递", "Leave outgoing parcels at the loading dock.", "将待寄包裹放在装卸区。"),
    ("printing", "打印", "Use double sided printing for draft documents.", "草稿文件请使用双面打印。"),
    ("wifi", "无线网络", "Visitors obtain a temporary network pass at reception.", "访客可在前台领取临时上网凭证。"),
    ("maintenance", "维修", "Report broken equipment to the facilities desk.", "设备损坏请向后勤服务台报修。"),
    ("parking", "停车", "Register the vehicle plate before entering the garage.", "进入车库前请登记车牌。"),
    ("training", "培训", "Complete the safety course before laboratory access.", "进入实验室前须完成安全课程。"),
    ("coffee", "咖啡", "Refill beans in the kitchen machine every morning.", "每天早上为厨房咖啡机补充咖啡豆。"),
    ("conference", "会展", "Show the badge at the exhibition entrance.", "在展览入口出示参会证件。"),
    ("invoice", "开票", "Include the purchase order when requesting an invoice.", "申请开票时请附上采购订单。"),
    ("warehouse", "仓库", "Scan the barcode before moving inventory.", "移动库存前请扫描条码。"),
    ("contract", "合同", "Legal counsel reviews every supplier agreement.", "每份供应商协议均须经法务审核。"),
]


def fixture():
    documents, queries = [], []
    for i, (en, zh, fact, chinese_fact) in enumerate(TOPICS):
        code = f"TS-{9000+i}"
        english, chinese = f"en-{i:02}", f"zh-{i:02}"
        documents.extend([
            {"id": english, "kind": "text", "text": f"{en.title()} instructions. {fact} Reference {code}."},
            {"id": chinese, "kind": "text", "text": f"{zh}说明。{chinese_fact}"},
            {"id": f"tail-{i:02}", "kind": "long_tail", "text": f"TAIL-{i:04} {en} {fact}"},
            {"id": f"scan-{i:02}", "kind": "scan", "text": f"SCAN-{i:04} {zh} {chinese_fact}", "page": 2},
            {"id": f"media-{i:02}", "kind": "audio" if i % 2 else "video", "text": f"{en} {fact}", "time": 45+i},
        ])
        cases = [
            ("lexical", f"{en} instructions", [english], "en", fact),
            ("identifier", code, [english], "en", code),
            ("chinese_short", zh, [chinese], "zh", chinese_fact),
            ("cross_language", f"{en} instructions" if i % 2 else zh, [chinese if i % 2 else english], "en" if i % 2 else "zh", chinese_fact if i % 2 else fact),
            ("long_tail", f"TAIL-{i:04}", [f"tail-{i:02}"], "en", f"TAIL-{i:04}"),
            ("scanned", f"SCAN-{i:04}", [f"scan-{i:02}"], "zh", f"SCAN-{i:04}"),
            ("media_timestamp", en, [f"media-{i:02}"], "en", fact),
            ("no_answer", f"unobtainium quantum zeppelin {i}", [], "en", None),
        ]
        for group, query, expected, language, anchor in cases:
            queries.append({"id": f"{group}-{i:02}", "group": group, "query": query,
                            "expected": expected, "language": language, "anchor": anchor,
                            "baseline_supported": group not in {"long_tail", "scanned", "media_timestamp"}})
    return {"version": 1, "provenance": "Hand-authored synthetic topic facts in scripts/create_semantic_query_fixture.py; labels point to document IDs and exact anchors. No personal files. This is a regression oracle, not a representative relevance benchmark. baseline_supported describes the text-only evaluation harness: long-tail and OCR fixtures are known gaps; media fixtures are unmeasured here even though visual/audio/video embedding exists in the product. Missing groups count as failures in the full denominator.",
            "documents": documents, "queries": queries}


if __name__ == "__main__":
    target = Path(__file__).resolve().parents[1] / "docs/validation/gul-383/optimization/queries.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(fixture(), ensure_ascii=False, indent=2) + "\n")
    print(f"Wrote {len(fixture()['queries'])} labelled queries")
