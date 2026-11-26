#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Offline check of tools/roku/ecp.py: survey (--watch, --until, --model),
the --model target, discover --save --model --identified, save-state and
restore-state, and the gates on actions (the go; a saved Roku identified
as the cabled one; its state saved before the first action). Two fake
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
    '127.0.0.1': dict(model='4850X', power='PowerOn', ecpm='enabled', app='', after720=4.0),
    '127.0.0.2': dict(model='4802X', power='Suspend', ecpm='permissive', app='12', after720=None),
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
evlog = open(os.environ['GC573_EVENT_LOG']).read()
check('event-log-private', '127.0.0' not in evlog and 'launch 12' not in evlog and '/12' not in evlog, '')
print(evlog)
shutil.rmtree(tmp, ignore_errors=True)
print('FAILS', fails)
sys.exit(1 if fails else 0)
