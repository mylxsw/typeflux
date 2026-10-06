#!/usr/bin/env python3
# wc: counts the selected text (or the text typed after the keyword).
# The simplest workflow: read the input, print the result.
import json
import re
import sys

request = json.loads(sys.stdin.readline() or "{}")
text = (sys.argv[1] if len(sys.argv) > 1 else "") or request.get("selection") or ""

# Chinese, Japanese and Korean characters count as one word each.
cjk = re.findall(r"[぀-ヿ㐀-鿿가-힯]", text)
latin = re.findall(r"[^\s぀-ヿ㐀-鿿가-힯]+", text)
words = len(cjk) + len(latin)
lines = len(text.splitlines()) if text else 0
characters = len(text)
visible = len(re.sub(r"\s", "", text))

print(f"{characters} characters · {visible} without spaces")
print(f"{words} {'word' if words == 1 else 'words'} · {lines} {'line' if lines == 1 else 'lines'}")
