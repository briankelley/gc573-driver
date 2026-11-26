#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Serve one file (the pattern video) to the Roku over HTTP, on the LAN and
only for the length of a test.
- Bound to the host's address on its route to the Roku (`ip route get`),
  port 8573 (--port).
- Answers the Roku's address only (ecp.py's GC573_ROKU or config file);
  anyone else gets 403, logged without their address.
- GET and HEAD, with Range (206): a player reads an MP4 in pieces.
- Stops after --secs, at SIGTERM or SIGINT, or when --pid ends.
- Logs each request to GC573_EVENT_LOG ("roku-http GET /NAME bytes=0- 206
  1048576"). No address is printed or logged: the URL goes to --url-file
  (mode 0600) for the caller, who must not log it either.
Usage: tools/roku/serve.py FILE --url-file F [--secs S] [--port P] [--pid P]
"""
import argparse
import http.server
import os
import re
import signal
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ecp  # noqa: E402


def route_src(addr):
    out = subprocess.run(['ip', '-4', 'route', 'get', addr],
                         capture_output=True, text=True).stdout
    m = re.search(r'\bsrc (\S+)', out)
    if not m:
        raise SystemExit('serve: no route to the Roku')
    return m.group(1)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('file')
    ap.add_argument('--url-file', required=True)
    ap.add_argument('--secs', type=float, default=3600)
    ap.add_argument('--port', type=int, default=8573)
    ap.add_argument('--pid', type=int, default=0,
                    help='stop when this process has ended')
    a = ap.parse_args()
    path = os.path.abspath(a.file)
    name = '/' + os.path.basename(path)
    size = os.path.getsize(path)
    roku = ecp.address()
    host = route_src(roku)

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, fmt, *args):
            pass                       # the default log has the address

        def note(self, code, rng, n):
            ecp.ev(f'http {self.command} {self.path.split("?")[0]} '
                   f'{rng or "-"} {code} {n}')

        def refuse(self, code):
            self.send_response(code)
            self.send_header('Content-Length', '0')
            self.end_headers()

        def serve(self, body):
            if self.client_address[0] != roku:
                self.note(403, None, 0)
                return self.refuse(403)
            if self.path.split('?')[0] != name:
                self.note(404, None, 0)
                return self.refuse(404)
            rng = self.headers.get('Range')
            start, end = 0, size - 1
            if rng:
                m = re.fullmatch(r'bytes=(\d*)-(\d*)', rng.strip())
                if not m or (not m.group(1) and not m.group(2)):
                    self.note(416, rng, 0)
                    return self.refuse(416)
                if m.group(1):
                    start = int(m.group(1))
                    if m.group(2):
                        end = min(int(m.group(2)), size - 1)
                else:                  # the last N bytes
                    start = max(0, size - int(m.group(2)))
                if start > end or start >= size:
                    self.send_response(416)
                    self.send_header('Content-Range', f'bytes */{size}')
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    self.note(416, rng, 0)
                    return
            n = end - start + 1
            self.send_response(206 if rng else 200)
            self.send_header('Content-Type', 'video/mp4')
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Length', str(n))
            if rng:
                self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.end_headers()
            sent = 0
            if body:
                with open(path, 'rb') as f:
                    f.seek(start)
                    while sent < n:
                        chunk = f.read(min(1 << 20, n - sent))
                        if not chunk:
                            break
                        try:
                            self.wfile.write(chunk)
                        except (BrokenPipeError, ConnectionResetError):
                            break
                        sent += len(chunk)
            self.note(206 if rng else 200, rng, sent)

        def do_GET(self):
            self.serve(True)

        def do_HEAD(self):
            self.serve(False)

    srv = http.server.ThreadingHTTPServer((host, a.port), Handler)
    srv.daemon_threads = True
    fd = os.open(a.url_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(f'http://{host}:{a.port}{name}\n')
    ecp.ev(f'http serving {name} ({size} bytes) for at most {a.secs:g} s')
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    end = time.monotonic() + a.secs
    while not stop.is_set() and time.monotonic() < end:
        if a.pid:
            try:
                os.kill(a.pid, 0)
            except ProcessLookupError:
                break
        stop.wait(1)
    srv.shutdown()
    srv.server_close()
    os.unlink(a.url_file)
    ecp.ev(f'http stopped serving {name}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
