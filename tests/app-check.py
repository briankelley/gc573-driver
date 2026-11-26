#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""A capture of tools/testsrc/avsync.sh --pattern written by another
application (tests/live.sh apps: ffmpeg, GStreamer, VLC), checked from the
file alone. Needs ffmpeg, ffprobe, numpy and PIL.

  app-check.py FILE WxH [--matrix bt709|bt601] [--ref MS] [--change S]

Every frame of the video stream is decoded once, in order, with its
timestamp (-fps_mode passthrough), and converted to RGB with the driver's
matrix (limited range; --matrix, default bt709), whatever the file says.
RESULT lines (PASS/FAIL/SKIP):

  media     the file holds a WxH video stream and a 2-channel 48 kHz audio
            stream
  frames    frame timestamps against the counter of avsync.sh --pattern:
            no timestamp gap over 1.5 frame periods, none under half a
            period, and every counter step 1 where the timestamps are
            regular. A counter step of 0 or 2 at a regular interval is the
            source's (its player's pacing: tests/logs/
            20261125T2115Z-testsrc-pacing.log) and only counted; a gap is
            a loss in the application or the driver, and fails
  pattern   frames at 10, 50 and 90 % against pattern.py: error <= 8
  channels  per burst the dominant frequency: left 1 kHz, right 2 kHz
            within 1 %, the other tone 30 dB down (live-av.py's test)
  rate      samples from one burst onset to the next: the source plays a
            burst every 60 frames (--fps: its frame rate, default 60), and
            the card's audio clock follows the source's, so 48000 x 60 /
            fps within 0.1 % (median; 48048 at 59.94 Hz); an application
            that resamples or drops audio fails
  avsync    burst onset - flash frame, from the file's own timestamps
            (SKIP when the container keeps none: the audio and video start
            together only by assumption). With --ref MS, the driver's own
            offset in the same source session (gc573-aud -V), the
            application's share is reported as well

--change S (a source change S seconds after the first frame): no frames,
pattern, channels, rate or avsync results; instead one CHANGE line: the
frames before S and from S + 3 (the source settled), the last frame's
time, the longest gap between frames after S, and what the frames from
S + 3 show: live (the counter moves with the frames, 80-120 %), frozen
(it does not move), jumpy, black (no counter, a dark frame: the driver
free-runs without an input), other (no counter, not dark) or none (no
frames)
"""
import argparse
import importlib.util
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('obs_events', os.path.join(HERE, 'obs-events.py'))
oe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oe)
RATE = 48000


def result(name, st, detail):
    print(f'RESULT {name:<9} {st} ({detail})', flush=True)


def probe(path):
    r = subprocess.run(['ffprobe', '-v', 'error', '-show_entries',
                        'stream=index,codec_type,codec_name,width,height,pix_fmt,sample_rate,channels,'
                        'start_time,avg_frame_rate:format=format_name,duration', '-of', 'json', path],
                       capture_output=True, text=True)
    return json.loads(r.stdout or '{}')


def frame_times(path):
    r = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                        'frame=best_effort_timestamp_time', '-of', 'csv=p=0', path],
                       capture_output=True, text=True)
    out = []
    for x in r.stdout.split():
        x = x.strip(',')
        out.append(float(x) if x not in ('', 'N/A') else float('nan'))
    return np.array(out)


def rgb_filter(matrix, extra=''):
    return f'{extra}scale=in_color_matrix={matrix}:in_range=tv:out_range=pc,format=rgb24'


def bands(path, W, H, matrix):
    """counter and flash luma of every frame (bottom fifth)"""
    y0 = H * 4 // 5
    p = subprocess.Popen(['ffmpeg', '-v', 'error', '-i', path, '-map', '0:v:0', '-fps_mode', 'passthrough',
                          '-vf', rgb_filter(matrix, f'crop={W}:{H - y0}:0:{y0},'), '-f', 'rawvideo', '-'],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    n = W * (H - y0) * 3
    _, _, flash = oe.geometry(W, H)
    fx0, fy0, fx1, fy1 = flash
    c, y = [], []
    while True:		# frame by frame: a 30 s capture is gigabytes of RGB
        b = p.stdout.read(n)
        if len(b) < n:
            break
        img = Image.frombytes('RGB', (W, H - y0), b)
        c.append(oe.counter_band(img, W, H))
        y.append(oe.luma(img, (fx0, fy0 - y0, fx1, fy1 - y0)))
    p.wait()
    return c, np.array(y)


def frame_at(path, t, matrix):
    r = subprocess.run(['ffmpeg', '-v', 'error', '-ss', f'{t:.3f}', '-i', path, '-map', '0:v:0',
                        '-frames:v', '1', '-vf', rgb_filter(matrix), '-f', 'image2pipe',
                        '-vcodec', 'png', '-'], capture_output=True)
    return Image.open(__import__('io').BytesIO(r.stdout)).convert('RGB') if r.stdout else None


def audio(path):
    r = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-map', '0:a:0', '-f', 's16le',
                        '-acodec', 'pcm_s16le', '-'], capture_output=True)
    return np.frombuffer(r.stdout, dtype='<i2')


def onsets_of(x):
    """first sample above 1/8 of full scale after >= 0.5 s of quiet"""
    out, last = [], -RATE
    env = np.abs(x.astype(np.int32)).max(axis=1)
    for k in np.flatnonzero(env > 4096):
        if k - last > RATE // 2:
            out.append(int(k))
        last = k
    return out


def channels(x, onsets):
    n, nfft = 800, 1 << 16
    f = np.fft.rfftfreq(nfft, 1 / RATE)
    i1, i2 = np.argmin(np.abs(f - 1000)), np.argmin(np.abs(f - 2000))
    fl, fr, bad, xtalk = [], [], 0, -np.inf
    for k in onsets:
        seg = x[k:k + n].astype(np.float64)
        if len(seg) < n:
            continue
        w = np.hanning(n)
        spec = [np.abs(np.fft.rfft(seg[:, ch] * w, nfft)) for ch in (0, 1)]
        peak = [f[np.argmax(s)] for s in spec]
        fl.append(peak[0])
        fr.append(peak[1])
        xt = max(20 * np.log10(spec[0][i2] / max(spec[0][i1], 1e-9)),
                 20 * np.log10(spec[1][i1] / max(spec[1][i2], 1e-9)))
        xtalk = max(xtalk, xt)
        if max(abs(peak[0] / 1000 - 1), abs(peak[1] / 2000 - 1)) > 0.01 or xt > -30:
            bad += 1
    return fl, fr, bad, xtalk


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('file')
    ap.add_argument('size')
    ap.add_argument('--matrix', default='bt709')
    ap.add_argument('--ref', type=float)
    ap.add_argument('--change', type=float)
    ap.add_argument('--fps', type=float, default=60.0)
    a = ap.parse_args()
    W, H = (int(v) for v in a.size.split('x'))
    info = probe(a.file)
    vs = [s for s in info.get('streams', []) if s.get('codec_type') == 'video']
    aus = [s for s in info.get('streams', []) if s.get('codec_type') == 'audio']
    fmt = info.get('format', {}).get('format_name', '?')
    vdesc = (f"video {vs[0].get('codec_name')} {vs[0].get('width')}x{vs[0].get('height')} "
             f"{vs[0].get('pix_fmt')}" if vs else 'no video')
    adesc = (f"audio {aus[0].get('codec_name')} {aus[0].get('sample_rate')} Hz "
             f"{aus[0].get('channels')} ch" if aus else 'no audio')
    media_ok = bool(vs) and vs[0].get('width') == W and vs[0].get('height') == H and bool(aus) and \
        str(aus[0].get('sample_rate')) == str(RATE) and aus[0].get('channels') == 2
    result('media', 'PASS' if media_ok else 'FAIL', f'{fmt}: {vdesc}; {adesc}')
    if not vs:
        return 1
    if vs[0].get('width') != W or vs[0].get('height') != H:
        W, H = vs[0]['width'], vs[0]['height']
    ts = frame_times(a.file)
    c, fy = bands(a.file, W, H, a.matrix)
    n = min(len(ts), len(c))
    ts, c, fy = ts[:n], c[:n], fy[:n]
    if n < 2:
        result('frames', 'FAIL', f'{n} frames decoded')
        return 1
    t0 = ts[0]
    have_ts = not np.isnan(ts).any() and np.all(np.diff(ts) > 0)
    period = float(np.median(np.diff(ts))) if have_ts else 1 / 60

    if a.change is not None:
        rel = ts - t0 if have_ts else np.arange(n) / 60
        settle = a.change + 3
        before = int(np.sum(rel < a.change))
        after = [i for i in range(n) if rel[i] >= settle]
        rd = [(i, c[i]) for i in after if c[i] is not None]
        if len(rd) >= 2:
            moved, frames = (rd[-1][1] - rd[0][1]) % 65536, rd[-1][0] - rd[0][0]
            prog = ('live' if 0.8 * frames <= moved <= 1.2 * frames else 'frozen' if moved == 0 else
                    f'jumpy ({moved} over {frames} frames)')
        elif after:
            img = frame_at(a.file, float(rel[-1]) - 0.05, a.matrix)
            dark = img is not None and oe.classify(img)[0] == 'black'
            prog = 'black' if dark else 'other'
        else:
            prog = 'none'
        post = rel[rel >= a.change]
        gap = float(np.max(np.diff(np.concatenate(([a.change], post))))) if len(post) else float('nan')
        print(f'CHANGE {before} frames before the change at {a.change:.1f} s, {len(after)} from '
              f'{settle:.1f} s (settled), the last at {rel[-1]:.2f} s; longest gap after the change '
              f'{gap:.2f} s; from {settle:.1f} s: {prog}', flush=True)
        return 0

    # frames: timestamp gaps, duplicates, and the counter at regular intervals
    gaps = dups = src0 = src2 = other = unread = 0
    if have_ts:
        for i in range(1, n):
            d = ts[i] - ts[i - 1]
            if d > 1.5 * period:
                gaps += 1
                continue
            if d < 0.5 * period:
                dups += 1
                continue
            if c[i] is None or c[i - 1] is None:
                unread += c[i] is None
                continue
            s = (c[i] - c[i - 1]) % 65536
            if s == 0:
                src0 += 1
            elif s == 2:
                src2 += 1
            elif s != 1:
                other += 1
        st = 'PASS' if gaps == 0 and dups == 0 and other == 0 else 'FAIL'
        result('frames', st, f'{n} frames, period {period * 1e3:.3f} ms; {gaps} timestamp gaps over '
               f'1.5 periods, {dups} under half; counter steps at regular intervals: {other} other '
               f'than 0, 1, 2; the source showed {src0} frames twice and skipped {src2}; '
               f'{unread} unreadable')
    else:
        steps = {}
        for i in range(1, n):
            if c[i] is not None and c[i - 1] is not None:
                s = (c[i] - c[i - 1]) % 65536
                steps[s] = steps.get(s, 0) + 1
        result('frames', 'SKIP', f'{n} frames without usable timestamps; counter steps '
               + ', '.join(f'{k}: {v}' for k, v in sorted(steps.items())))

    errs = []
    dur = (ts[-1] - t0) if have_ts else n / 60
    for frac in (0.1, 0.5, 0.9):
        img = frame_at(a.file, frac * dur, a.matrix)
        if img is not None:
            kind, err, _, _ = oe.classify(img)
            errs.append(f'{kind} {err}')
    ok = len(errs) == 3 and all(e.startswith('pattern ') and int(e.split()[1]) <= oe.TOL for e in errs)
    result('pattern', 'PASS' if ok else 'FAIL', f'frames at 10/50/90 %: {", ".join(errs)} (limit {oe.TOL})')

    if not aus:
        return 0
    x = audio(a.file)
    ach = aus[0].get('channels') or 2
    x = x[:len(x) // ach * ach].reshape(-1, ach)
    if ach != 2:
        result('channels', 'FAIL', f'{ach} channels')
        return 0
    onsets = onsets_of(x)
    fl, fr, bad, xtalk = channels(x, onsets)
    result('channels', 'PASS' if fl and bad == 0 else 'FAIL',
           f'left {np.mean(fl) if fl else 0:.1f} Hz, right {np.mean(fr) if fr else 0:.1f} Hz over '
           f'{len(fl)} bursts, other tone <= {xtalk:.1f} dB, {bad} bad')
    # flashes: first frame of each run of bright flash boxes
    hot = fy > 128
    flashes = [i for i in range(n) if hot[i] and (i == 0 or not hot[i - 1])]
    a0 = float(aus[0].get('start_time') or 0)
    pairs = []
    for i in flashes:
        tv = ts[i] if have_ts else t0 + i / 60
        cand = [k for k in onsets if abs(a0 + k / RATE - tv) < 0.5]
        if cand:
            k = min(cand, key=lambda k: abs(a0 + k / RATE - tv))
            pairs.append((tv, k))
    # a burst every 60 source frames: 1.001 s of its audio at 59.94 Hz
    per = RATE * round(a.fps) / a.fps
    d = np.diff(onsets)
    d = d[np.abs(d - per) < per * 0.05]
    if len(d) >= 3:
        r = float(np.median(d))
        result('rate', 'PASS' if abs(r / per - 1) < 1e-3 else 'FAIL',
               f'{r:.1f} samples from one burst to the next (median of {len(d)}; '
               f'{per:.1f} for a source at {a.fps:g} Hz), {(r / per - 1) * 1e6:+.0f} ppm')
    else:
        result('rate', 'FAIL', f'{len(onsets)} bursts, {len(d)} about {per / RATE:.3f} s apart')
    if not have_ts or len(pairs) < 4:
        result('avsync', 'SKIP', 'no usable timestamps' if not have_ts else 'too few pairs')
        return 0
    off = np.array([(a0 + k / RATE - tv) * 1e3 for tv, k in pairs])
    med = float(np.median(off))
    detail = (f'burst onset - flash frame over {len(off)} flashes: median {med:+.1f} ms, mean '
              f'{off.mean():+.1f}, std {off.std():.1f}, min {off.min():+.1f}, max {off.max():+.1f} '
              f'(positive: audio late)')
    if a.ref is not None:
        detail += f'; the driver {a.ref:+.1f} ms in the same source session: the application ' \
                  f'{med - a.ref:+.1f} ms'
    ok = -45 <= med <= 125
    result('avsync', 'PASS' if ok else 'FAIL', detail + '; BT.1359: -45 to +125 ms')
    return 0


if __name__ == '__main__':
    sys.exit(main())
