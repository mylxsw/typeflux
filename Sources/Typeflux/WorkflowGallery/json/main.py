#!/usr/bin/env python3
# json: formats the selected JSON (or JSON typed after the keyword); `json min` compacts it.
# Selection-only runs write back automatically; runs with arguments show a preview.
import re
import json
import sys

request = json.loads(sys.stdin.readline() or "{}")
query = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
mode = re.match(r"^(min|-c|compact|pretty)(?:\s+([\s\S]*))?$", query)
compact = bool(mode and mode[1] != "pretty")
text = (mode[2] if mode and mode[2] is not None else request.get("selection") or "") if mode or not query else query

try:
    value = json.loads(text)
except ValueError as error:
    print(json.dumps({"error": f"Not valid JSON: {error}"}))
    sys.exit(1)

if compact:
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
else:
    print(json.dumps(value, ensure_ascii=False, indent=2))
