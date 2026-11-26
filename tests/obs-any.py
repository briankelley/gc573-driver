#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""OBS on whatever the source shows, numbers only (M6: the Roku when it
cannot play our pattern). No picture leaves memory, and nothing is kept.
  shots N [--every S]  N screenshots of the V4L2 source, S s apart (1):
                       their size, mean luma, and how much each differs
                       from the one before (mean |difference| of a 160x90
                       grey copy, in codes)
  meters SECS          the audio source's InputVolumeMeters over SECS s:
                       how many, peak and mean level per channel (dBFS)
  stats                OBS's GetStats: render and output frames, skipped
                       frames, CPU, memory (a STATS line)
  reopen-video         OBS closes and opens the V4L2 device (color_range
                       toggled, as tests/obs-events.py does)
  reopen-audio         the same for the ALSA source (custom_pcm between two
                       names of the same PCM)
  record-start [--dir D]  OBS starts recording (to D, SetRecordDirectory;
                       its own directory is put back at record-stop); its
                       GetStats then, in a 0600 file for record-stop
  record-stop          OBS stops recording: the file (RECORDING), OBS's
                       render and output frames and skipped frames over
                       the recording (STATS), and the recording's length,
                       frame count and frame rate from ffprobe (INFO). The
                       caller deletes the file: it shows what the source
                       showed
Uses tests/obs-events.py's connection, source names and event log
(GC573_EVENT_LOG). --host: OBS_HOST, else 127.0.0.1 in local mode
(GC573_VM=local), else gc573-dev's address. RESULT lines for shots and
meters; exit 1 on a FAIL.
"""
import argparse
import importlib.util
import json
import math
import os
import subprocess
import sys
import time

from PIL import Image, ImageChops, ImageStat

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location('obsevents', os.path.join(HERE, 'obs-events.py'))
oe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(oe)


def cmd_shots(obs, n, every):
    src = oe.Source(obs)
    sizes, lumas, diffs = [], [], []
    prev, fails = None, 0
    for i in range(n):
        if i:
            time.sleep(every)
        try:
            img, _, _ = src.shot()
        except Exception:  # noqa: BLE001 (a failed screenshot is a result)
            fails += 1
            continue
        g = img.convert('L')
        sizes.append(img.size)
        lumas.append(ImageStat.Stat(g).mean[0])
        small = g.resize((160, 90), Image.BILINEAR)
        if prev is not None:
            diffs.append(ImageStat.Stat(ImageChops.difference(small, prev)).mean[0])
        prev = small
    ok = fails == 0 and len(set(sizes)) == 1
    size = f'{sizes[0][0]}x{sizes[0][1]}' if sizes else 'none'
    lum = f'{min(lumas):.0f}-{max(lumas):.0f}' if lumas else '-'
    moved = sum(1 for d in diffs if d > 0.5)
    mean = sum(diffs) / len(diffs) if diffs else 0.0
    print(f"RESULT any-shots {'PASS' if ok else 'FAIL'} ({len(sizes)} of {n} screenshots {size}"
          f"{'' if len(set(sizes)) <= 1 else ' (sizes differ)'}, {fails} failed; luma {lum}; "
          f"{moved} of {len(diffs)} differ from the one before (mean {mean:.1f} codes))")
    return ok


def cmd_meters(host, secs):
    obs = oe.OBS(host=host, events=1 << 16)
    t_end = time.monotonic() + secs
    n = m = 0
    peak, acc = [-200.0, -200.0], [0.0, 0.0]
    while time.monotonic() < t_end:
        e = obs.next_event(1.0)
        if not e or e.get('eventType') != 'InputVolumeMeters':
            continue
        n += 1
        for inp in e['eventData']['inputs']:
            if inp.get('inputName') != oe.ASRC or not inp.get('inputLevelsMul'):
                continue
            m += 1
            for c, ch in enumerate(inp['inputLevelsMul'][:2]):
                db = 20 * math.log10(ch[1]) if ch[1] > 0 else -200.0
                peak[c] = max(peak[c], db)
                acc[c] += db
    obs.close()
    mean = [a / m if m else -200.0 for a in acc]
    ok = m > 0
    print(f"RESULT any-meters {'PASS' if ok else 'FAIL'} ({n} InputVolumeMeters events in {secs} s, "
          f"{m} with the audio source; peak L {peak[0]:.1f} R {peak[1]:.1f} dBFS, "
          f"mean L {mean[0]:.1f} R {mean[1]:.1f} dBFS)")
    return ok


def cmd_stats(obs):
    s = obs.call('GetStats')
    keys = ('activeFps', 'renderTotalFrames', 'renderSkippedFrames', 'outputTotalFrames',
            'outputSkippedFrames', 'cpuUsage', 'memoryUsage')
    print('STATS ' + ' '.join(f'{k}={s.get(k)}' for k in keys))
    return True


REC_STATE = os.path.join(os.environ.get('XDG_RUNTIME_DIR') or '/tmp', 'gc573-obs-any-rec.json')
STAT_KEYS = ('renderSkippedFrames', 'renderTotalFrames', 'outputSkippedFrames', 'outputTotalFrames')


def cmd_record_start(obs, rec_dir):
    if obs.call('GetRecordStatus')['outputActive']:
        print('OBS is recording already: not started', file=sys.stderr)
        return False
    old = None
    if rec_dir:
        old = obs.call('GetRecordDirectory')['recordDirectory']
        obs.call('SetRecordDirectory', recordDirectory=rec_dir)
    fd = os.open(REC_STATE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump({'dir': old, 'stats': obs.call('GetStats')}, f)
    oe.ev(f'obs record start{" to " + rec_dir if rec_dir else ""}')
    obs.call('StartRecord')
    for _ in range(50):
        if obs.call('GetRecordStatus')['outputActive']:
            print('STARTED')
            return True
        time.sleep(0.1)
    print('the recording did not start', file=sys.stderr)
    return False


def probe(path):
    """the recording's length, video frames and frame rate (ffprobe,
    packets counted: nothing decoded)"""
    r = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-count_packets',
                        '-show_entries', 'stream=nb_read_packets,avg_frame_rate,width,height',
                        '-show_entries', 'format=duration', '-of', 'json', path],
                       capture_output=True, text=True, timeout=600)
    try:
        d = json.loads(r.stdout)
        st = d['streams'][0]
        n, dur = int(st['nb_read_packets']), float(d['format']['duration'])
        a, _, b = st['avg_frame_rate'].partition('/')
        fps = float(a) / float(b or 1)
    except (ValueError, KeyError, IndexError, ZeroDivisionError):
        return f'ffprobe could not read it: {r.stderr.strip()[:160]}'
    return (f'{st.get("width")}x{st.get("height")}, {dur:.1f} s, {n} video frames at '
            f'{fps:.3f} fps ({n - dur * fps:+.0f} against length x rate)')


def cmd_record_stop(obs):
    try:
        with open(REC_STATE) as f:
            st = json.load(f)
    except FileNotFoundError:
        st = {'dir': None, 'stats': None}
    oe.ev('obs record stop')
    path = obs.call('StopRecord')['outputPath']
    s1 = obs.call('GetStats')
    if st['dir']:
        obs.call('SetRecordDirectory', recordDirectory=st['dir'])
    if os.path.exists(REC_STATE):
        os.remove(REC_STATE)
    print('RECORDING', path)
    if st['stats']:
        print('STATS ' + ' '.join(f'{k}={s1[k] - st["stats"][k]}' for k in STAT_KEYS))
    for _ in range(20):
        if os.path.exists(path) and os.path.getsize(path):
            break
        time.sleep(0.5)
    print(f'INFO recording: {probe(path)}')
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--host', default=os.environ.get(
        'OBS_HOST', '127.0.0.1' if oe.LOCAL else '192.168.122.40'))
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('shots')
    p.add_argument('n', type=int)
    p.add_argument('--every', type=float, default=1.0)
    sub.add_parser('meters').add_argument('secs', type=int)
    for name in ('stats', 'reopen-video', 'reopen-audio', 'record-stop'):
        sub.add_parser(name)
    sub.add_parser('record-start').add_argument('--dir', default='')
    a = ap.parse_args()
    if a.cmd == 'meters':
        return 0 if cmd_meters(a.host, a.secs) else 1
    obs = oe.OBS(host=a.host)
    try:
        if a.cmd == 'shots':
            ok = cmd_shots(obs, a.n, a.every)
        elif a.cmd == 'stats':
            ok = cmd_stats(obs)
        elif a.cmd == 'record-start':
            ok = cmd_record_start(obs, a.dir)
        elif a.cmd == 'record-stop':
            ok = cmd_record_stop(obs)
        elif a.cmd == 'reopen-video':
            oe.Source(obs).reopen()
            ok = True
        else:
            print(f'INFO {oe.reopen_audio(obs)}')
            ok = True
    finally:
        obs.close()
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
