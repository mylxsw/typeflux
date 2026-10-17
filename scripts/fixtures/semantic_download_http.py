#!/usr/bin/env python3
"""Loopback-only deterministic interrupted downloads; no external model weights."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import sys
import time

root = Path(sys.argv[1])
payload = bytes(range(256)) * 1024
prefix = 65536
counts = {}


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_GET(self):
        mode = self.path.strip('/')
        counts[mode] = counts.get(mode, 0) + 1
        attempt = counts[mode]
        range_header = self.headers.get('Range')
        offset = int(range_header[6:-1]) if range_header else 0
        changed = mode == 'change' and attempt > 1
        body = payload[::-1] if changed or mode == 'hash' else payload
        etag = '"v2"' if changed or (mode == 'etag206' and attempt > 1) else '"v1"'
        resume = bool(range_header) and mode not in ('ignore', 'change')
        status = 206 if resume else 200
        start = offset if resume else 0
        self.send_response(status)
        self.send_header('ETag', etag)
        self.send_header('Content-Length', str(len(body) - start))
        if resume:
            advertised = start + 1 if mode == 'wrong' else start
            self.send_header('Content-Range', f'bytes {advertised}-{len(body)-1}/{len(body)}')
        self.end_headers()
        interrupted = (attempt == 1 and mode not in ('hash', 'slow')) or mode == 'truncated'
        record = {'mode': mode, 'attempt': attempt, 'range': range_header,
                  'if_range': self.headers.get('If-Range'), 'status': status,
                  'etag': etag, 'start': start, 'interrupted': interrupted,
                  'full_sha256': hashlib.sha256(body).hexdigest(), 'prefix_bytes': prefix}
        with (root / 'requests.jsonl').open('a') as output:
            output.write(json.dumps(record) + '\n')
        try:
            if interrupted:
                self.wfile.write(body[start:start + prefix]); self.wfile.flush()
                # Close only after the real delegate has persisted these socket bytes.
                # An immediate close can fail before CFNetwork dispatches didReceive(data:).
                for _ in range(400):
                    persisted = [p.stat().st_size for p in (root / 'downloads').glob('*/payload')]
                    if persisted and max(persisted) >= start + prefix:
                        break
                    time.sleep(0.005)
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
            elif mode == 'slow':
                for index in range(start, len(body), 4096):
                    self.wfile.write(body[index:index + 4096]); self.wfile.flush()
                    time.sleep(0.01)
            else:
                self.wfile.write(body[start:]); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(root / 'port').write_text(str(server.server_address[1]))
server.serve_forever()
