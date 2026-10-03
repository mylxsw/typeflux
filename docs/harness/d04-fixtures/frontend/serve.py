"""D02 listener adapter: no bind, subprocess, package install or outbound I/O."""
import os
from pathlib import Path
import socket

listener = socket.socket(fileno=int(os.environ['TYPEFLUX_LISTEN_FD']))
token = os.environ['TYPEFLUX_READY_TOKEN']
resources = {'/index.html': 'index.html', '/app.js': 'app.js', '/style.css': 'style.css'}
print('Service uses the inherited listener')
while True:
    client, _ = listener.accept()
    with client:
        client.settimeout(1)
        try:
            request = client.recv(8192).split(b' ')
            path = request[1].decode('ascii') if len(request) > 1 else ''
            status = '200 OK'
            if path == '/__typeflux_ready/' + token:
                body = token.encode()
            elif path in resources and request[0] == b'GET':
                body = Path(resources[path]).read_bytes()
            else:
                status, body = '404 Not Found', b'Unavailable'
            client.sendall(('HTTP/1.1 ' + status + '\r\nContent-Length: ' + str(len(body))
                            + '\r\nConnection: close\r\n\r\n').encode() + body)
        except (OSError, UnicodeError):
            pass
