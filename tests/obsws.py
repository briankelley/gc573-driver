#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Minimal obs-websocket (protocol v5) client on the Python standard library,
for the OBS checks (tests/obs-check.py). With authentication on (OBS:
Tools, WebSocket Server Settings), the password comes from OBS_PASSWORD or,
for an OBS on this machine, from OBS's own settings.

As a module:  obs = OBS(); obs.call('GetVersion')
              OBS(events=1 << 16): subscribe to events (here
              InputVolumeMeters); obs.next_event(timeout) returns the next
              one (events that arrive during a call are kept for it)
As a command: obsws.py REQUEST [JSON]   prints the response data as JSON
Host: OBS_HOST in the environment, or 127.0.0.1.
"""
import base64
import collections
import hashlib
import json
import os
import select
import socket
import struct
import sys
import time


class OBS:
    def __init__(self, host=None, port=4455, timeout=30, events=0):
        host = host or os.environ.get('OBS_HOST', '127.0.0.1')
        self.s = socket.create_connection((host, port), timeout=timeout)
        self.timeout = timeout
        self.buf = b''
        self.n = 0
        self.events = collections.deque()
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f'GET / HTTP/1.1\r\nHost: {host}:{port}\r\n'
                        'Upgrade: websocket\r\nConnection: Upgrade\r\n'
                        f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n'
                        'Sec-WebSocket-Protocol: obswebsocket.json\r\n\r\n').encode())
        while b'\r\n\r\n' not in self.buf:
            d = self.s.recv(4096)
            if not d:
                raise OSError('websocket handshake: connection closed')
            self.buf += d
        head, self.buf = self.buf.split(b'\r\n\r\n', 1)
        if b' 101 ' not in head.split(b'\r\n')[0] + b' ':
            raise OSError('websocket handshake: ' + head.decode(errors='replace'))
        hello = self.recv()
        if hello.get('op') != 0:
            raise OSError(f'expected Hello, got {hello}')
        ident = {'rpcVersion': 1, 'eventSubscriptions': events}
        auth = hello['d'].get('authentication')
        if auth:
            ident['authentication'] = self._auth(auth, host)
        self.send({'op': 1, 'd': ident})
        if self.recv().get('op') != 2:
            raise OSError('not identified')

    @staticmethod
    def _auth(auth, host):
        """obs-websocket v5 authentication string. The password comes from
        OBS_PASSWORD, or for an OBS on this machine from its own settings
        (OBS_CONFIG, default ~/.config/obs-studio)."""
        pw = os.environ.get('OBS_PASSWORD')
        if pw is None and host in ('127.0.0.1', 'localhost', '::1'):
            cfg = os.environ.get('OBS_CONFIG',
                                 os.path.expanduser('~/.config/obs-studio'))
            try:
                with open(os.path.join(cfg, 'plugin_config', 'obs-websocket',
                                       'config.json')) as f:
                    pw = json.load(f).get('server_password')
            except (OSError, ValueError):
                pw = None
        if not pw:
            raise OSError('OBS asks for a password: set OBS_PASSWORD')
        h = lambda s: base64.b64encode(hashlib.sha256(s.encode()).digest()).decode()
        return h(h(pw + auth['salt']) + auth['challenge'])

    def _read(self, n):
        while len(self.buf) < n:
            d = self.s.recv(max(1 << 16, n - len(self.buf)))
            if not d:
                raise OSError('websocket: connection closed')
            self.buf += d
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _frame(self, op, data):
        mask = os.urandom(4)
        n = len(data)
        if n < 126:
            hdr = struct.pack('>BB', 0x80 | op, 0x80 | n)
        elif n < 1 << 16:
            hdr = struct.pack('>BBH', 0x80 | op, 0x80 | 126, n)
        else:
            hdr = struct.pack('>BBQ', 0x80 | op, 0x80 | 127, n)
        self.s.sendall(hdr + mask + bytes(c ^ mask[i & 3] for i, c in enumerate(data)))

    def send(self, obj):
        self._frame(1, json.dumps(obj).encode())

    def recv(self):
        msg = b''
        while True:
            b0, b1 = self._read(2)
            n = b1 & 0x7f
            if n == 126:
                n = struct.unpack('>H', self._read(2))[0]
            elif n == 127:
                n = struct.unpack('>Q', self._read(8))[0]
            mask = self._read(4) if b1 & 0x80 else None
            data = self._read(n)
            if mask:
                data = bytes(c ^ mask[i & 3] for i, c in enumerate(data))
            op = b0 & 0x0f
            if op == 9:		# ping
                self._frame(10, data)
                continue
            if op == 10:	# pong
                continue
            if op == 8:
                raise OSError('websocket closed by OBS')
            msg += data
            if b0 & 0x80:
                return json.loads(msg)

    def call(self, rtype, **data):
        self.n += 1
        rid = str(self.n)
        self.send({'op': 6, 'd': {'requestType': rtype, 'requestId': rid,
                                  'requestData': data}})
        while True:
            m = self.recv()
            if m.get('op') == 5:
                self.events.append(m['d'])
                continue
            if m.get('op') == 7 and m['d'].get('requestId') == rid:
                st = m['d']['requestStatus']
                if not st.get('result'):
                    raise RuntimeError(f"{rtype}: code {st.get('code')} {st.get('comment', '')}")
                return m['d'].get('responseData', {})

    def next_event(self, timeout):
        """The next event (op 5) as its data, or None after timeout s"""
        if self.events:
            return self.events.popleft()
        end = time.monotonic() + timeout
        while True:
            left = end - time.monotonic()
            if left <= 0:
                return None
            # wait for the start of a message only: a whole message is
            # then read with the normal timeout
            if not self.buf and not select.select([self.s], [], [], left)[0]:
                return None
            m = self.recv()
            if m.get('op') == 5:
                return m['d']

    def close(self):
        try:
            self._frame(8, b'')
        finally:
            self.s.close()


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    obs = OBS()
    print(json.dumps(obs.call(sys.argv[1], **(json.loads(sys.argv[2]) if len(sys.argv) > 2 else {})), indent=1))
    obs.close()
