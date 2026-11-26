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
  settings > Control by mobile apps set to "Enabled"; the documentation
  names no setting for launch and input.
- GET query/active-app: the app in the foreground (id, type, version,
  name; Roku's SDK documentation, docs/REFERENCES/rsg-2.0-sdk/
  rsg-sdk-rk-cli/rsg-sdk-rk-ecp.md in the same repository).

Privacy (AGENTS.md "Roku"): the Roku's identifiers never leave memory.
- The address comes from GC573_ROKU or from ~/.config/gc573/roku (mode
  0600, a line "address=..."), which `discover --save` writes. It is
  never printed or logged.
- device-info (serial, device id, MACs, the user's name for the device)
  is read in memory, and only the model and the software version are
  printed.
- The SSDP reply's USN carries the serial: never printed.
- query/media-player names the app playing, which shows what the user
  watches: only its state is printed, and whether the app is ours; the
  position and duration too for ours only. Ours is Play on Roku (15985)
  alone: the sideloaded developer channel (dev) on the user's Roku is
  their own app, never launched here (restore-state alone could).

- query/active-app names the app in the foreground: save-state keeps its
  id in a 0600 file for restore-state, and never prints or logs it.

Actions (keypress, launch, input) change what the Roku does, and the
user may be using it: they need GC573_ROKU_GO=1. Each request goes to
GC573_EVENT_LOG (without the address). On the saved Roku an action also
needs it identified as the one cabled to the card (an "identified=" line
in the config: tests/live.sh rokuwhich), unless GC573_ROKU names it, and
the first action records its state (save-state) unless a state is saved
already, for the record. tests/live.sh does not restore it (the user
does, from their workstation): at the run's end it only stops our own
video if it still plays (stop-ours).
--model M (before the command) talks to the Roku of model number M,
found by SSDP, instead of the saved one: no identification needed, no
state saved.

Usage:
  ecp.py discover [--save [--pick N | --model M]] [--timeout S]
                               find Rokus by SSDP; --save keeps one's
                               address (--model: the one of model number M)
  ecp.py survey [--saved] [--watch S [--until KEY=VALUE [--model M]]]
                               every Roku's model, software, power mode,
                               ui-resolution and ECP setting; --watch: every
                               2 s for S s, a line at each change, until a
                               Roku (of model M) has device-info KEY=VALUE
                               (MATCH, exit 0; else NO MATCH, exit 1);
                               --saved: the saved Roku's alone (GC573_ROKU
                               or the config), no SSDP: nothing reaches any
                               other Roku
  ecp.py save-state [--file F] the foreground app, the power mode and the
                               model, in F (~/.config/gc573/roku-state,
                               0600); a file that is there already is kept
  ecp.py stop-ours             (GC573_ROKU_GO=1) stop our video if it is in
                               the media player (Home), else nothing
  ecp.py restore-state [--file F]  (GC573_ROKU_GO=1; by hand only) PowerOff if it was in
                               Suspend, else the app launched again if it
                               was neither ours nor the home screen;
                               not for a state of another model
  ecp.py info                  model and software version (and, for a
                               saved Roku not identified as the cabled
                               one, that it is not)
  ecp.py state                 media player state (position and duration
                               for ours only)
  ecp.py power                 power mode (PowerOn, DisplayOff, ...)
  ecp.py key KEY...            keypresses (GC573_ROKU_GO=1)
  ecp.py launch APP [K=V...]   launch an app (GC573_ROKU_GO=1)
  ecp.py play URL              play a video URL (GC573_ROKU_GO=1) through
                               Play on Roku: input/15985 with t=v, u=URL,
                               as phones cast to it (not in Roku's ECP
                               documentation; HTTP 404 on the user's
                               Roku). There is no other way: never through
                               the user's own app
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
STATE = os.path.expanduser('~/.config/gc573/roku-state')
# --model: the Roku of this model number (SSDP) instead of the saved one
TARGET_MODEL = ''
_target = []
SSDP = ('239.255.255.250', 1900)
MSEARCH = ('M-SEARCH * HTTP/1.1\r\n'
           'Host: 239.255.255.250:1900\r\n'
           'Man: "ssdp:discover"\r\n'
           'ST: roku:ecp\r\n'
           '\r\n')
# ours: Play on Roku. Not dev: the sideloaded channel on the user's Roku
# is their own app
OURS = {'15985'}
PLAYING = {'open', 'startup', 'buffer', 'play', 'pause'}
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
    """The Roku's address: --model's, GC573_ROKU, else the config file"""
    if TARGET_MODEL:
        if not _target:
            hits = [x for x in ssdp() if model_of(x) == TARGET_MODEL]
            if len(hits) != 1:
                raise EcpError(f'{len(hits)} Rokus of model {TARGET_MODEL} answer')
            _target.append(hits[0])
        return _target[0]
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


def write_private(path, text):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(text)
    os.chmod(path, 0o600)


def save_address(a, how=''):
    """how: how the Roku was found to be the one cabled to the card"""
    t = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    write_private(CONF, f'address={a}\n' + (f'identified={how} {t}\n' if how else ''))


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


def model_of(addr):
    try:
        return device_info(addr).get('model-number', '')
    except EcpError:
        return ''


def survey_text(info):
    """one Roku's line: nothing that identifies it"""
    return (f"{info.get('model-number', '?')}: {info.get('model-name', '?')}, "
            f"software {info.get('software-version', '?')} build "
            f"{info.get('software-build', '?')}, {info.get('power-mode', '?')}, "
            f"ui-resolution {info.get('ui-resolution', '?')}, "
            f"ecp {info.get('ecp-setting-mode', '?')}")


def survey(addrs, watch, until, model):
    """survey's loop (see the usage); the exit status"""
    key, _, value = until.partition('=')
    shown = {}
    t0 = time.monotonic()
    while True:
        el = time.monotonic() - t0
        for i, a in enumerate(addrs, 1):
            try:
                info = device_info(a)
                line = survey_text(info)
            except EcpError as e:
                info, line = None, f'Roku {i}: {e}'
            if shown.get(i) != line:
                print((f'+{el:.0f} s ' if watch else '') + line, flush=True)
                shown[i] = line
            if (key and info and info.get(key) == value and
                    (not model or info.get('model-number') == model)):
                print(f"MATCH {info.get('model-number', '?')} after {el:.0f} s")
                return 0
        if not key:
            return 0
        if el >= watch:
            print(f'NO MATCH after {watch:.0f} s: no Roku'
                  f'{" of model " + model if model else ""} with {until}')
            return 1
        time.sleep(2)


def active_app():
    """(app id or '', kind: home, ours or other) of query/active-app"""
    root = ET.fromstring(request('GET', 'query/active-app'))
    app = root.find('app')
    aid = (app.get('id') or '') if app is not None else ''
    return aid, 'home' if not aid else 'ours' if aid in OURS else 'other'


KIND_TEXT = {'home': 'the home screen', 'ours': 'one of ours', 'other': 'another app'}


def save_state(path):
    if os.path.exists(path):
        print(f'a saved Roku state is there already, from a run that did not '
              f'restore it: kept ({path})')
        return
    ev('query active-app and device-info (the state to restore)')
    aid, kind = active_app()
    info = device_info()
    pm = info.get('power-mode', '?')
    write_private(path, f"app={aid}\nkind={kind}\npower={pm}\n"
                        f"model={info.get('model-number', '')}\n")
    print(f'Roku state saved: power mode {pm}, in the foreground {KIND_TEXT[kind]} ({path}, 0600)')


def restore_state(path):
    need_go('restore-state')
    try:
        st = dict(line.strip().split('=', 1) for line in open(path) if '=' in line)
    except FileNotFoundError:
        print('no saved Roku state: nothing to restore')
        return
    model = device_info().get('model-number', '')
    if st.get('model') and st['model'] != model:
        print(f"the saved state is of another Roku (model {st['model']}, the saved "
              f"Roku is a {model}): not restored, kept ({path})")
        return
    if st.get('power') == 'Suspend':
        keypress('PowerOff')
        done = 'PowerOff, as it was in Suspend'
    elif st.get('kind') == 'other' and st.get('app'):
        action('launch')
        ev('launch (the app saved before the run)')
        request('POST', f"launch/{urllib.parse.quote(st['app'], safe='')}")
        done = 'the app it had in the foreground launched again'
    else:
        done = f"nothing to do: it had {KIND_TEXT.get(st.get('kind'), '?')} in the foreground"
    os.remove(path)
    time.sleep(3)
    try:
        now = device_info().get('power-mode', '?')
    except EcpError as e:
        now = str(e)
    print(f'Roku state restored: {done}; power mode now {now}')


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


def need_go(what):
    if os.environ.get('GC573_ROKU_GO') != '1':
        raise EcpError(f'{what}: an action, which needs GC573_ROKU_GO=1 '
                       '(the go to use the Roku: the user may be using it)')


def identified():
    """the config says how the saved Roku was found to be the cabled one"""
    try:
        with open(CONF) as f:
            return any(line.startswith('identified=') for line in f)
    except FileNotFoundError:
        return False


def action(what):
    """an action: the go; on the saved Roku its identification, and its
    state saved before the first one"""
    need_go(what)
    if TARGET_MODEL:
        return
    if not os.environ.get('GC573_ROKU', '').strip() and not identified():
        raise EcpError(f'{what}: the saved Roku is not known to be the one '
                       'cabled to the card (tests/live.sh rokuwhich)')
    if not os.path.exists(STATE):
        save_state(STATE)


def keypress(key):
    if key not in KEYS and not key.startswith('Lit_'):
        raise EcpError(f'key {key}: not a key of the ECP documentation')
    action(f'keypress {key}')
    ev(f'keypress {key}')
    request('POST', f'keypress/{key}')


def launch(app, params=None):
    if app == 'dev':
        raise EcpError('launch dev: the sideloaded channel is the user\'s own '
                       'app, never launched here')
    action(f'launch {app}')
    ev(f'launch {app}' + (f' ({", ".join(params)})' if params else ''))
    request('POST', f'launch/{app}', params)


def play(url):
    """Play on Roku, the one way: never the user's own app"""
    action('play')
    # the URL's host is this machine's LAN address: the path only
    ev(f'play {urllib.parse.urlsplit(url).path} via pol')
    request('POST', 'input/15985',
            {'t': 'v', 'u': url, 'videoName': 'gc573-pattern',
             'k': '(null)', 'videoFormat': 'mp4'})


def player_app():
    """(state, the id of the app in the media player or ''), in memory"""
    root = ET.fromstring(request('GET', 'query/media-player'))
    plugin = root.find('plugin')
    return root.get('state'), (plugin.get('id') or '') if plugin is not None else ''


def stop_ours():
    """Stop our video if it is in the media player; what was done"""
    need_go('stop-ours')
    ev('query media-player (is ours playing?)')
    st, app = player_app()
    if app in OURS and st in PLAYING:
        keypress('Home')
        return f'our video was in the media player ({st}): Home'
    return f"nothing of ours playing (media player {st}{'' if app in OURS else ', not ours'})"


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
    d.add_argument('--model', default='',
                   help='with --save: the Roku of this model number')
    d.add_argument('--identified', default='',
                   help='with --save: how it was found to be the cabled one')
    d.add_argument('--timeout', type=float, default=3.0)
    sv = sub.add_parser('survey')
    sv.add_argument('--watch', type=float, default=0)
    sv.add_argument('--until', default='', help='KEY=VALUE of device-info')
    sv.add_argument('--model', default='')
    sv.add_argument('--saved', action='store_true',
                    help='the saved Roku alone, without SSDP')
    sv.add_argument('--timeout', type=float, default=3.0)
    for name in ('save-state', 'restore-state'):
        sub.add_parser(name).add_argument('--file', default=STATE)
    sub.add_parser('info')
    sub.add_parser('state')
    sub.add_parser('power')
    k = sub.add_parser('key')
    k.add_argument('keys', nargs='+')
    k.add_argument('--gap', type=float, default=0.5)
    la = sub.add_parser('launch')
    la.add_argument('app')
    la.add_argument('params', nargs='*', help='K=V')
    sub.add_parser('play').add_argument('url')
    sub.add_parser('stop-ours')
    ap.add_argument('--model', dest='target', default='',
                    help='the Roku of this model number (SSDP), not the saved one')
    a = ap.parse_args()
    global TARGET_MODEL
    TARGET_MODEL = a.target
    try:
        if a.cmd == 'survey':
            every = f' every 2 s for {a.watch:.0f} s' if a.watch else ''
            if a.saved:
                ev(f'query device-info of the saved Roku{every}')
                return survey([address()], a.watch, a.until, a.model)
            ev(f'discover (SSDP), then device-info{every}')
            found = ssdp(a.timeout)
            if not found:
                print('no Roku answered (ECP off, another subnet, or '
                      'multicast blocked)')
                return 1
            return survey(found, a.watch, a.until, a.model)
        if a.cmd == 'save-state':
            save_state(a.file)
        elif a.cmd == 'restore-state':
            restore_state(a.file)
        elif a.cmd == 'discover':
            ev('discover (SSDP)')
            found = ssdp(a.timeout)
            if not found:
                print('no Roku answered (ECP off, another subnet, or '
                      'multicast blocked): set GC573_ROKU instead')
                return 1
            models = []
            for i, addr in enumerate(found, 1):
                try:
                    info = device_info(addr)
                    text = model_text(info)
                except EcpError as e:
                    info, text = {}, str(e)
                models.append(info.get('model-number', ''))
                print(f'Roku {i}: {text}')
            if a.save:
                if a.model:
                    hits = [x for x, m in zip(found, models) if m == a.model]
                    if len(hits) != 1:
                        print(f'{len(hits)} Rokus of model {a.model}: none saved')
                        return 1
                    pick = hits[0]
                elif len(found) > 1 and not a.pick:
                    print('several Rokus: give --pick N or --model M')
                    return 1
                else:
                    pick = found[(a.pick or 1) - 1]
                save_address(pick, a.identified)
                print(f'address saved in {CONF} (mode 0600)'
                      f'{", identified: " + a.identified if a.identified else ""}')
        elif a.cmd == 'info':
            ev('query device-info')
            # the saved Roku is one of two on the LAN: say when nothing
            # has shown it is the one on the card's input
            unknown = not (TARGET_MODEL or os.environ.get('GC573_ROKU', '').strip()
                           or identified())
            print(model_text(device_info()) +
                  (' (the saved Roku, not yet identified as the one cabled to '
                   'the card)' if unknown else ''))
        elif a.cmd == 'state':
            ev('query media-player')
            st, pos, dur, ours = media_state()
            print(f'state {st}' + (f' position {pos} s duration {dur} s app ours'
                                   if ours else ' app not ours'))
        elif a.cmd == 'stop-ours':
            print(stop_ours())
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
            play(a.url)
    except EcpError as e:
        print(f'ecp: {e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
