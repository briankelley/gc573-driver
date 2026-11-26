#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Offline check of tests/obs-any.py settings-save and settings-restore
against a fake OBS (no network, no OBS). OBS saves its sources at exit,
so the reopens' changes stay in the user's scene collection unless they
are put back: the V4L2 source's color_range and the ALSA source's
custom_pcm. After the Roku soaks of 2026-11-26 an odd number of reopens
left color_range 1 (from 0) and custom_pcm without ",DEV=0".
Checks:
- the reopens change the settings (the condition of that bug);
- restore puts back what save saw, after odd and even reopen counts;
- a save kept from a run that did not restore stays the one put back;
- a setting not set at the save gets its default;
- restore without a save does nothing.
The state file goes in a temporary XDG_RUNTIME_DIR.
Usage: tests/obs-any-check.py   (PASS/FAIL lines; exit 1 on a failure)
"""
import contextlib
import importlib.util
import io
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ['XDG_RUNTIME_DIR'] = tempfile.mkdtemp()
os.environ['GC573_VM'] = 'local'
os.environ.pop('GC573_EVENT_LOG', None)
spec = importlib.util.spec_from_file_location('obs_any', os.path.join(HERE, 'obs-any.py'))
oa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oa)
oe = oa.oe
PCM = 'hw:CARD=/dev/snd/by-path/pci-0000:07:00.0,DEV=0'
KIND = {oe.VSRC: 'v4l2_input', oe.ASRC: 'alsa_input_capture'}
DEFAULTS = {'v4l2_input': {'color_range': 0}, 'alsa_input_capture': {'device_id': 'default'}}
fails = 0


def check(name, ok, detail=''):
    global fails
    print(f'{"PASS" if ok else "FAIL"} {name} {detail}'.rstrip())
    if not ok:
        fails += 1


class FakeOBS:
    def __init__(self, video, audio):
        self.s = {oe.VSRC: dict(video), oe.ASRC: dict(audio)}

    def call(self, method, **kw):
        if method == 'GetInputSettings':
            n = kw['inputName']
            return {'inputSettings': dict(self.s[n]), 'inputKind': KIND[n]}
        if method == 'SetInputSettings':
            self.s[kw['inputName']].update(kw['inputSettings'])
            return {}
        if method == 'GetInputDefaultSettings':
            return {'defaultInputSettings': DEFAULTS[kw['inputKind']]}
        raise RuntimeError(f'fake OBS: no {method}')


def quiet(f, *a):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        r = f(*a)
    return r, out.getvalue()


def reopens(obs, video, audio):
    for _ in range(video):
        oe.Source(obs).reopen()
    for _ in range(audio):
        quiet(oe.reopen_audio, obs)


USER = ({'color_range': 0, 'buffering': False}, {'device_id': '__custom__', 'custom_pcm': PCM})
missing = [n for n in ('cmd_settings_save', 'cmd_settings_restore') if not hasattr(oa, n)]
check('settings-commands', not missing, f'(missing: {", ".join(missing)})' if missing else '')
if missing:
    print(f'FAILS {fails}')
    sys.exit(1)

# the bug's condition: one reopen of each changes both settings
obs = FakeOBS(*USER)
reopens(obs, 1, 1)
check('reopen-changes', obs.s[oe.VSRC]['color_range'] == 1 and obs.s[oe.ASRC]['custom_pcm'] != PCM,
      repr(obs.s))
for name, v, a in (('restore-odd', 7, 1), ('restore-even', 2, 2), ('restore-none', 0, 0)):
    obs = FakeOBS(*USER)
    ok1, _ = quiet(oa.cmd_settings_save, obs)
    reopens(obs, v, a)
    ok2, out = quiet(oa.cmd_settings_restore, obs)
    check(name, ok1 and ok2 and obs.s == FakeOBS(*USER).s and not os.path.exists(oa.SET_STATE),
          f'({v} video and {a} audio reopens: {out.strip()})')
# a save kept from a run that did not restore: a second save keeps it
obs = FakeOBS(*USER)
quiet(oa.cmd_settings_save, obs)
reopens(obs, 1, 1)
_, out = quiet(oa.cmd_settings_save, obs)
reopens(obs, 1, 0)
ok, out2 = quiet(oa.cmd_settings_restore, obs)
check('save-kept', ok and 'kept' in out and obs.s == FakeOBS(*USER).s, f'({out.strip()}; {out2.strip()})')
# color_range not set at the save: its default after the restore
obs = FakeOBS({'buffering': False}, USER[1])
quiet(oa.cmd_settings_save, obs)
reopens(obs, 1, 0)
ok, out = quiet(oa.cmd_settings_restore, obs)
check('restore-default', ok and obs.s[oe.VSRC].get('color_range') == 0, f'({out.strip()})')
# no save: nothing done
obs = FakeOBS(*USER)
reopens(obs, 1, 0)
ok, out = quiet(oa.cmd_settings_restore, obs)
check('restore-without-save', ok and obs.s[oe.VSRC]['color_range'] == 1 and 'none saved' in out,
      f'({out.strip()})')
print(f'FAILS {fails}')
sys.exit(1 if fails else 0)
