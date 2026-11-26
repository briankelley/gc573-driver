#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Roku External Control Protocol (ECP) client for the GC573 tests.

From Roku's public ECP documentation (developer.roku.com, "External
Control Protocol"; its source is docs/DEVELOPER/dev-tools/
external-control-api.md in gitlab.com/rokudev/dev-doc, branch v2.0):
- discovery by SSDP: an M-SEARCH to 239.255.255.250:1900 with ST roku:ecp;
  each Roku answers with LOCATION http://<address>:8060/;
- HTTP on port 8060: GET query/device-info, GET query/media-player, POST
  keypress/KEY, POST launch/APP (deep link: contentId, mediaType), POST
  input (name-value pairs for the app running). Since Roku OS 14.1
  keypress and some queries need Settings > System > Advanced system
  settings > Control by mobile apps.

Privacy (AGENTS.md "Roku"): the Roku's identifiers never leave memory.
- The address comes from GC573_ROKU or from ~/.config/gc573/roku (mode
  0600, a line "address=..."), which `discover --save` writes. It is
  never printed or logged.
- device-info (serial, device id, MACs, the user's name for the device)
  is read in memory, and only the model and the software version are
  printed.
- The SSDP reply's USN carries the serial: never printed.
- query/media-player names the app playing, which shows what the user
  watches: only its state, position and duration are printed, and
  whether the app is one of ours.

Actions (keypress, launch, input) change what the Roku does, and the
user may be using it: they need GC573_ROKU_GO=1. Each request goes to
GC573_EVENT_LOG (without the address).

Usage:
  ecp.py discover [--save] [--timeout S]  find Rokus by SSDP
  ecp.py info                  model and software version
  ecp.py state                 media player state, position, duration
  ecp.py power                 power mode (PowerOn, DisplayOff, ...)
  ecp.py key KEY...            keypresses (GC573_ROKU_GO=1)
  ecp.py launch APP [K=V...]   launch an app (GC573_ROKU_GO=1)
  ecp.py play URL [--via V]    play a video URL (GC573_ROKU_GO=1):
      pol   input/15985 with t=v, u=URL (Play on Roku, as phones cast to
            it; not in Roku's ECP documentation)
      dev   launch/dev with url=URL and streamformat=mp4: a sideloaded
            developer channel that plays the url it is given (Roku's ECP
            documentation, its sample program; developer mode)
"""
import argparse
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                '..', 'testsrc'))
from scrub import scrub  # noqa: E402

PORT = 8060
CONF = os.path.expanduser('~/.config/gc573/roku')
SSDP = ('239.255.255.250', 1900)
MSEARCH = ('M-SEARCH * HTTP/1.1\r\n'
           'Host: 239.255.255.250:1900\r\n'
           'Man: "ssdp:discover"\r\n'
           'ST: roku:ecp\r\n'
           '\r\n')
# apps whose state may be printed: ours (Play on Roku, a sideloaded one)
OURS = {'15985', 'dev'}
KEYS = {'Home', 'Rev', 'Fwd', 'Play', 'Select', 'Left', 'Right', 'Down',
        'Up', 'Back', 'InstantReplay', 'Info', 'Backspace', 'Search',
        'Enter', 'PowerOff'}


class EcpError(Exception):
    pass


def ev(text):
    log = os.environ.get('GC573_EVENT_LOG')
    if log:
        t = time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime())
        ms = int(time.time() * 1000) % 1000
        with open(log, 'a') as f:
            f.write(f'{t}.{ms:03d}Z roku {scrub(text)}\n')


def address():
    """The Roku's address: GC573_ROKU, else the config file"""
    a = os.environ.get('GC573_ROKU', '').strip()
    if a:
        return a
    try:
        st = os.stat(CONF)
    except FileNotFoundError:
        raise EcpError(f'no Roku address: set GC573_ROKU or run '
                       f'"ecp.py discover --save" ({CONF})')
    if st.st_mode & 0o077:
        raise EcpError(f'{CONF} is readable by others: chmod 600 it')
    with open(CONF) as f:
        for line in f:
            k, _, v = line.strip().partition('=')
            if k == 'address' and v:
                return v
    raise EcpError(f'{CONF} has no "address=" line')


def save_address(a):
    d = os.path.dirname(CONF)
    os.makedirs(d, mode=0o700, exist_ok=True)
    fd = os.open(CONF, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(f'address={a}\n')
    os.chmod(CONF, 0o600)


def request(method, path, params=None, timeout=5.0, addr=None):
    """One ECP request; the body (bytes). Errors name the path only."""
    a = addr or address()
    url = f'http://{a}:{PORT}/{path}'
    if params:
        url += '?' + urllib.parse.urlencode(params, safe='()')
    req = urllib.request.Request(url, method=method,
                                 data=b'' if method == 'POST' else None)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        hint = ''
        if e.code in (401, 403):
            hint = (': is Control by mobile apps on (Settings > System > '
                    'Advanced system settings)?')
        raise EcpError(f'{method} {path}: HTTP {e.code}{hint}') from None
    except (urllib.error.URLError, OSError) as e:
        reason = getattr(e, 'reason', e)
        # the reason can carry the address: name its kind only
        raise EcpError(f'{method} {path}: no answer '
                       f'({type(reason).__name__})') from None


def device_info(addr=None):
    """query/device-info as a dict, in memory only"""
    root = ET.fromstring(request('GET', 'query/device-info', addr=addr))
    return {c.tag: (c.text or '').strip() for c in root}


def model_text(info):
    return (f"model {info.get('model-name', '?')} "
            f"{info.get('model-number', '?')}, software "
            f"{info.get('software-version', '?')} build "
            f"{info.get('software-build', '?')}")


def media_state():
    """(state, position s, duration s, ours) from query/media-player"""
    root = ET.fromstring(request('GET', 'query/media-player'))
    plugin = root.find('plugin')
    ours = plugin is not None and plugin.get('id') in OURS

    def ms(tag):
        el = root.find(tag)
        m = re.match(r'\s*(\d+)', el.text or '') if el is not None else None
        return int(m.group(1)) / 1000 if m else None
    return root.get('state'), ms('position'), ms('duration'), ours


def action(what):
    if os.environ.get('GC573_ROKU_GO') != '1':
        raise EcpError(f'{what}: an action, which needs GC573_ROKU_GO=1 '
                       '(the go to use the Roku: the user may be using it)')


def keypress(key):
    if key not in KEYS and not key.startswith('Lit_'):
        raise EcpError(f'key {key}: not a key of the ECP documentation')
    action(f'keypress {key}')
    ev(f'keypress {key}')
    request('POST', f'keypress/{key}')


def launch(app, params=None):
    action(f'launch {app}')
    ev(f'launch {app}' + (f' ({", ".join(params)})' if params else ''))
    request('POST', f'launch/{app}', params)


def play(url, via='pol'):
    action(f'play ({via})')
    # the URL's host is this machine's LAN address: the path only
    ev(f'play {urllib.parse.urlsplit(url).path} via {via}')
    if via == 'pol':
        request('POST', 'input/15985',
                {'t': 'v', 'u': url, 'videoName': 'gc573-pattern',
                 'k': '(null)', 'videoFormat': 'mp4'})
    elif via == 'dev':
        request('POST', 'launch/dev', {'url': url, 'streamformat': 'mp4'})
    else:
        raise EcpError(f'play: no way "{via}"')


def ssdp(timeout=3.0):
    """The addresses that answer an ECP M-SEARCH, in memory"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    s.settimeout(0.5)
    found = []
    try:
        for _ in range(2):
            s.sendto(MSEARCH.encode(), SSDP)
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                data, _ = s.recvfrom(4096)
            except socket.timeout:
                continue
            hdr = {}
            for line in data.decode('latin-1').split('\r\n')[1:]:
                k, _, v = line.partition(':')
                hdr[k.strip().lower()] = v.strip()
            if hdr.get('st', '').lower() != 'roku:ecp':
                continue
            m = re.match(r'http://([^/:]+):(\d+)/', hdr.get('location', ''))
            if m and int(m.group(2)) == PORT and m.group(1) not in found:
                found.append(m.group(1))
    finally:
        s.close()
    return found


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    d = sub.add_parser('discover')
    d.add_argument('--save', action='store_true')
    d.add_argument('--pick', type=int, default=0,
                   help='with several Rokus: the one to save (1, 2, ...)')
    d.add_argument('--timeout', type=float, default=3.0)
    sub.add_parser('info')
    sub.add_parser('state')
    sub.add_parser('power')
    k = sub.add_parser('key')
    k.add_argument('keys', nargs='+')
    k.add_argument('--gap', type=float, default=0.5)
    la = sub.add_parser('launch')
    la.add_argument('app')
    la.add_argument('params', nargs='*', help='K=V')
    p = sub.add_parser('play')
    p.add_argument('url')
    p.add_argument('--via', default='pol', choices=('pol', 'dev'))
    a = ap.parse_args()
    try:
        if a.cmd == 'discover':
            ev('discover (SSDP)')
            found = ssdp(a.timeout)
            if not found:
                print('no Roku answered (ECP off, another subnet, or '
                      'multicast blocked): set GC573_ROKU instead')
                return 1
            for i, addr in enumerate(found, 1):
                try:
                    text = model_text(device_info(addr))
                except EcpError as e:
                    text = str(e)
                print(f'Roku {i}: {text}')
            if a.save:
                if len(found) > 1 and not a.pick:
                    print('several Rokus: give --pick N')
                    return 1
                save_address(found[(a.pick or 1) - 1])
                print(f'address saved in {CONF} (mode 0600)')
        elif a.cmd == 'info':
            ev('query device-info')
            print(model_text(device_info()))
        elif a.cmd == 'state':
            ev('query media-player')
            st, pos, dur, ours = media_state()
            print(f'state {st} position {pos} s duration {dur} s app '
                  f'{"ours" if ours else "not ours"}')
        elif a.cmd == 'power':
            ev('query device-info (power mode)')
            print(device_info().get('power-mode', '?'))
        elif a.cmd == 'key':
            for i, key in enumerate(a.keys):
                if i:
                    time.sleep(a.gap)
                keypress(key)
        elif a.cmd == 'launch':
            launch(a.app, dict(kv.split('=', 1) for kv in a.params))
        elif a.cmd == 'play':
            play(a.url, a.via)
    except EcpError as e:
        print(f'ecp: {e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
