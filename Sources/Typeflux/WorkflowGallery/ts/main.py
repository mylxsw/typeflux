#!/usr/bin/env python3
# ts: a Unix timestamp -> dates; a date -> the timestamp; nothing -> now.
# Without an argument the selected text is used (it arrives on stdin with the request).
import json
import sys
from datetime import datetime, timezone

request = json.loads(sys.stdin.readline() or "{}")
text = ((sys.argv[1] if len(sys.argv) > 1 else "") or request.get("selection") or "").strip()

FORMATS = ["%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d", "%Y/%m/%d %H:%M:%S", "%Y/%m/%d"]


def show(moment):
    print(moment.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"))
    print(moment.astimezone().strftime("%Y-%m-%d %H:%M:%S %z (local)"))


if not text:
    now = datetime.now(timezone.utc)
    show(now)
    print(f"{int(now.timestamp())} (seconds)")
elif text.lstrip("-").replace(".", "", 1).isdigit():
    value = float(text)
    # 13 digits and more are milliseconds.
    seconds = value / 1000 if abs(value) >= 1e12 else value
    show(datetime.fromtimestamp(seconds, timezone.utc))
    print(f"{text} ({'milliseconds' if seconds != value else 'seconds'})")
else:
    for pattern in FORMATS:
        try:
            moment = datetime.strptime(text, pattern).astimezone()
            break
        except ValueError:
            continue
    else:
        try:
            moment = datetime.fromisoformat(text)
            moment = moment if moment.tzinfo else moment.astimezone()
        except ValueError:
            print(json.dumps({"error": f"Not a timestamp or a date: {text}"}))
            sys.exit(1)
    print(int(moment.timestamp()))
    print(f"{int(moment.timestamp() * 1000)} (milliseconds)")
    show(moment)
