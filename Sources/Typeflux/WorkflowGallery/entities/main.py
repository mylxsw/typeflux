#!/usr/bin/env python3
"""Escape HTML text, or decode named/numeric HTML entities. No HTML is rendered."""
import html
import json
import re
import sys

def transform(query, selection=''):
    match = re.match(r'^(-[ed])(?:\s+([\s\S]*))?$', query)
    mode = match[1] if match else '-e'
    text = (match[2] if match and match[2] is not None else selection) if match else query or selection
    if not text:
        raise ValueError('Type: entities -e <text> or entities -d &amp;')
    return html.unescape(text) if mode == '-d' else html.escape(text, quote=True)

if __name__ == '__main__':
    try:
        request = json.loads(sys.stdin.readline() or '{}')
        print(transform(sys.argv[1] if len(sys.argv)>1 else '', request.get('selection') or ''))
    except (ValueError, TypeError) as error:
        print(json.dumps({'error':str(error)})); sys.exit(1)
