#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Offline check of tools/roku/ecp.py: survey (--watch, --until, --model),
the --model target, discover --save --model --identified, save-state and
restore-state, stop-ours, and the gates on actions (the go; a saved Roku
identified as the cabled one; its state saved before the first action).
Ours is Play on Roku alone: the sideloaded dev channel (the user's own
app) is never launched but by restore-state and, once the user's handoff
is there and enabled, by play --via user-app; of it only the player
state is printed. Two fake
Rokus answer on 127.0.0.1 and 127.0.0.2 port 8060, and SSDP is replaced:
no network, no real Roku. The config, the state file and the event log
are in a temporary directory, never ~/.config/gc573. Checks too that no
identifier of a fake Roku (serial, MAC, name, address) and no app id is
printed or logged.
Usage: tests/ecp-check.py   (prints PASS/FAIL lines; exit 1 on a failure)
"""
import contextlib
import http.server
import io
import os
import shutil
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools', 'roku'))
import ecp  # noqa: E402

for v in ('GC573_ROKU', 'GC573_ROKU_GO', 'GC573_EVENT_LOG'):
    os.environ.pop(v, None)
T0 = time.monotonic()
LOG = []
ROKUS = {
    '127.0.0.1': dict(model='4850X', power='PowerOn', ecpm='enabled', app='', after720=4.0,
                      plugin='dev', mstate='play'),
    '127.0.0.2': dict(model='4802X', power='Suspend', ecpm='permissive', app='12', after720=None,
                      plugin='15985', mstate='play'),
}
SECRET = 'SERIALX123456'


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def r(self):
        return ROKUS[self.server.server_address[0]]

    def do_GET(self):
        r = self.r()
        if self.path == '/query/device-info':
            ui = '720p' if r['after720'] is not None and time.monotonic() - T0 > r['after720'] else '1080p'
            body = (f'<device-info><serial-number>{SECRET}</serial-number>'
                    f'<wifi-mac>aa:bb:cc:dd:ee:ff</wifi-mac>'
                    f'<user-device-name>Living room</user-device-name>'
                    f'<model-name>Fake Player</model-name><model-number>{r["model"]}</model-number>'
                    f'<software-version>16.0.4</software-version><software-build>853</software-build>'
                    f'<power-mode>{r["power"]}</power-mode><ui-resolution>{ui}</ui-resolution>'
                    f'<ecp-setting-mode>{r["ecpm"]}</ecp-setting-mode></device-info>')
        elif self.path == '/query/media-player':
            body = (f'<player error="false" state="{r["mstate"]}"><plugin id="{r["plugin"]}" '
                    f'name="X"/><position>4321 ms</position><duration>98765 ms</duration></player>')
        elif self.path == '/query/active-app':
            body = ('<active-app>' + (f'<app id="{r["app"]}" type="appl" version="1">Netflix</app>'
                                      if r['app'] else '<app>Roku</app>') + '</active-app>')
        else:
            self.send_response(404)
            self.end_headers()
            return
        b = body.encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_POST(self):
        LOG.append((self.server.server_address[0], self.path))
        self.send_response(200)
        self.send_header('Content-Length', '0')
        self.end_headers()


for a in ROKUS:
    srv = http.server.ThreadingHTTPServer((a, 8060), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

tmp = tempfile.mkdtemp()
os.environ['GC573_EVENT_LOG'] = os.path.join(tmp, 'ev.log')
ecp.CONF = os.path.join(tmp, 'roku')
ecp.STATE = os.path.join(tmp, 'roku-state')
ecp.USER_APP = os.path.join(tmp, 'user-app')
ecp.ssdp = lambda timeout=3.0: list(ROKUS)
fails = 0


def check(name, ok, detail=''):
    global fails
    fails += not ok
    print(f"{'PASS' if ok else 'FAIL'} {name} {detail}")


def run(f, *a):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = f(*a)
    return rc, out.getvalue()


# 1. survey --watch --until: the 4850X follows after about 4 s
rc, out = run(ecp.survey, list(ROKUS), 12, 'ui-resolution=720p', '')
check('survey-match', rc == 0 and 'MATCH 4850X' in out, repr(out.splitlines()[-1]))
check('survey-private', SECRET not in out and 'aa:bb' not in out and 'Living' not in out and '127.0.0' not in out)
print(out)
# 2. no match for the other model within 3 s
rc, out = run(ecp.survey, list(ROKUS), 3, 'ui-resolution=720p', '4802X')
check('survey-nomatch', rc == 1 and 'NO MATCH' in out, repr(out.splitlines()[-1]))
# 3. --model target
ecp.TARGET_MODEL = '4802X'
check('target-model', ecp.address() == '127.0.0.2')
ecp.TARGET_MODEL, ecp._target[:] = '', []
# 4. discover --save --model --identified
sys.argv = ['ecp.py', 'discover', '--save', '--model', '4850X', '--identified', 'edid-720p']
rc, out = run(ecp.main)
conf = open(ecp.CONF).read()
check('discover-save-model', rc == 0 and 'address=127.0.0.1' in conf and 'identified=edid-720p' in conf
      and oct(os.stat(ecp.CONF).st_mode & 0o777) == '0o600', repr(conf))
check('discover-private', '127.0.0' not in out and SECRET not in out, repr(out))
# 5. save-state on the 4802X (Suspend, an app): the id stays in the file
os.environ['GC573_ROKU'] = '127.0.0.2'
st = os.path.join(tmp, 'state')
rc, out = run(ecp.save_state, st)
check('save-state', open(st).read() == 'app=12\nkind=other\npower=Suspend\nmodel=4802X\n' and '12' not in out
      and oct(os.stat(st).st_mode & 0o777) == '0o600', repr(out))
rc, out = run(ecp.save_state, st)
check('save-state-kept', 'kept' in out)
# 6. restore without the go refuses; with it: PowerOff (it was in Suspend)
os.environ.pop('GC573_ROKU_GO', None)
try:
    ecp.restore_state(st)
    check('restore-needs-go', False)
except ecp.EcpError as e:
    check('restore-needs-go', 'GC573_ROKU_GO' in str(e))
os.environ['GC573_ROKU_GO'] = '1'
LOG.clear()
rc, out = run(ecp.restore_state, st)
check('restore-poweroff', LOG == [('127.0.0.2', '/keypress/PowerOff')] and not os.path.exists(st), repr(LOG))
# 7. PowerOn with another app: launched again, its id not logged
open(st, 'w').write('app=12\nkind=other\npower=PowerOn\n')
LOG.clear()
rc, out = run(ecp.restore_state, st)
check('restore-launch', LOG == [('127.0.0.2', '/launch/12')] and '12' not in out, repr(LOG))
# 8. home screen: nothing sent
open(st, 'w').write('app=\nkind=home\npower=PowerOn\n')
LOG.clear()
rc, out = run(ecp.restore_state, st)
check('restore-home', LOG == [] and 'nothing to do' in out, repr(out))
# 9. an action on a saved Roku that is not identified: refused; info
# says it is not identified
os.environ.pop('GC573_ROKU', None)
ecp.STATE = os.path.join(tmp, 'roku-state')
open(ecp.CONF, 'w').write('address=127.0.0.2\n')
os.chmod(ecp.CONF, 0o600)
sys.argv = ['ecp.py', 'info']
rc, out = run(ecp.main)
check('info-not-identified', rc == 0 and '4802X' in out and 'not yet identified' in out, repr(out))
try:
    ecp.keypress('Home')
    check('needs-identified', False)
except ecp.EcpError as e:
    check('needs-identified', 'rokuwhich' in str(e), str(e))
# 10. identified: info without the note; the first action saves the
# state, then acts
open(ecp.CONF, 'w').write('address=127.0.0.2\nidentified=edid-720p x\n')
rc, out = run(ecp.main)
check('info-identified', rc == 0 and '4802X' in out and 'identified' not in out, repr(out))
LOG.clear()
rc, out = run(ecp.keypress, 'Home')
check('lazy-save', os.path.exists(ecp.STATE) and 'model=4802X' in open(ecp.STATE).read()
      and LOG == [('127.0.0.2', '/keypress/Home')], repr(out))
m0 = os.stat(ecp.STATE).st_mtime_ns
rc, out = run(ecp.keypress, 'Home')
check('lazy-save-once', os.stat(ecp.STATE).st_mtime_ns == m0 and out == '', repr(out))
# 11. restore: PowerOff (Suspend), the file gone
LOG.clear()
rc, out = run(ecp.restore_state, ecp.STATE)
check('restore-after-lazy', LOG == [('127.0.0.2', '/keypress/PowerOff')] and not os.path.exists(ecp.STATE), repr(out))
# 12. a state of another model: kept, nothing sent
open(ecp.STATE, 'w').write('app=\nkind=home\npower=Suspend\nmodel=4850X\n')
LOG.clear()
rc, out = run(ecp.restore_state, ecp.STATE)
check('restore-other-model', LOG == [] and os.path.exists(ecp.STATE) and 'another Roku' in out, repr(out))
os.remove(ecp.STATE)
# 13. --model target: no identification, no state
open(ecp.CONF, 'w').write('address=127.0.0.2\n')
ecp.TARGET_MODEL, ecp._target[:] = '4850X', []
LOG.clear()
rc, out = run(ecp.keypress, 'Info')
check('target-no-gate', LOG == [('127.0.0.1', '/keypress/Info')] and not os.path.exists(ecp.STATE), repr(out))
ecp.TARGET_MODEL, ecp._target[:] = '', []
# 14. ours is Play on Roku alone; dev is never launched or played
check('ours-15985-only', ecp.OURS == {'15985'}, repr(ecp.OURS))
for name, f in (('launch-dev-refused', lambda: ecp.launch('dev')),
                ('play-dev-refused', lambda: ecp.play('http://x/y.mp4', 'dev'))):
    LOG.clear()
    try:
        f()
        check(name, False)
    except ecp.EcpError as e:
        check(name, LOG == [] and ('user' in str(e) or 'pol' in str(e)), str(e))
# 15. state: of dev (not ours) the state only; of ours position and duration
os.environ['GC573_ROKU'] = '127.0.0.1'
sys.argv = ['ecp.py', 'state']
rc, out = run(ecp.main)
check('state-not-ours', out.strip() == 'state play app not ours', repr(out))
os.environ['GC573_ROKU'] = '127.0.0.2'
rc, out = run(ecp.main)
check('state-ours', 'position 4.321 s duration 98.765 s app ours' in out, repr(out))
# 16. stop-ours: Home for ours playing; nothing for dev
for addr, want in (('127.0.0.2', [('127.0.0.2', '/keypress/Home')]), ('127.0.0.1', [])):
    os.environ['GC573_ROKU'] = addr
    LOG.clear()
    rc, out = run(lambda: print(ecp.stop_ours()))
    check(f'stop-ours-{ROKUS[addr]["plugin"]}', LOG == want, repr(out))
# 17. dev in front at the first action: kind other; restore-state (by
# hand) is the one path that may launch it again
os.environ['GC573_ROKU'] = '127.0.0.1'
ROKUS['127.0.0.1']['app'] = 'dev'
if os.path.exists(ecp.STATE):
    os.remove(ecp.STATE)
rc, out = run(ecp.save_state, ecp.STATE)
check('save-dev-other', 'kind=other' in open(ecp.STATE).read() and 'dev' not in out, repr(out))
LOG.clear()
rc, out = run(ecp.restore_state, ecp.STATE)
check('restore-dev', LOG == [('127.0.0.1', '/launch/dev')], repr(LOG))
# 18. play through the user's app: refused until the handoff is there,
# private and enabled; then launch/dev with its parameters; stop-ours
# --via user-app with its stop key, only while dev plays
os.environ['GC573_ROKU'] = '127.0.0.1'
url = 'http://192.0.2.9:8573/p.mp4'
handoff = 'launch=contentId={url}&mediaType=movie\nstop=key:Back\n'
for name, text, mode in (('user-app-no-handoff', None, 0o600),
                         ('user-app-not-enabled', handoff + 'enabled=no\n', 0o600),
                         ('user-app-not-private', handoff + 'enabled=yes\n', 0o644)):
    if os.path.exists(ecp.USER_APP):
        os.remove(ecp.USER_APP)
    if text is not None:
        open(ecp.USER_APP, 'w').write(text)
        os.chmod(ecp.USER_APP, mode)
    LOG.clear()
    try:
        ecp.play(url, 'user-app')
        check(name, False)
    except ecp.EcpError as e:
        check(name, LOG == [], str(e))
os.chmod(ecp.USER_APP, 0o600)
LOG.clear()
rc, out = run(ecp.play, url, 'user-app')
check('user-app-play', LOG == [('127.0.0.1', '/launch/dev?contentId=http%3A%2F%2F192.0.2.9%3A8573%2Fp.mp4'
                               '&mediaType=movie')], repr(LOG))
LOG.clear()
rc, out = run(lambda: print(ecp.stop_ours('user-app')))
check('user-app-stop', LOG == [('127.0.0.1', '/keypress/Back')], repr(out))
ROKUS['127.0.0.1']['mstate'] = 'close'
LOG.clear()
rc, out = run(lambda: print(ecp.stop_ours('user-app')))
check('user-app-stop-idle', LOG == [] and 'not playing' in out, repr(out))
evlog = open(os.environ['GC573_EVENT_LOG']).read()
check('event-log-private', '127.0.0' not in evlog and '192.0.2.9' not in evlog and 'launch 12' not in evlog
      and '/12' not in evlog, '')
print(evlog)
shutil.rmtree(tmp, ignore_errors=True)
print('FAILS', fails)
sys.exit(1 if fails else 0)
