#!/usr/bin/env python3
# json: formats the selected JSON (or JSON typed after the keyword); `json min` compacts it.
# The result is written back over the selection.
import json
import sys

request = json.loads(sys.stdin.readline() or "{}")
query = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
compact = query in ("min", "-c", "compact")
text = request.get("selection") or "" if compact or not query else query

try:
    value = json.loads(text)
except ValueError as error:
    print(json.dumps({"error": f"Not valid JSON: {error}"}))
    sys.exit(1)

if compact:
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
else:
    print(json.dumps(value, ensure_ascii=False, indent=2))
