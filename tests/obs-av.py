#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""A/V offset in a recording of tools/testsrc/avsync.sh (an OBS recording
of the GC573 sources, tests/live.sh step obsav): the time of each flash
frame in the file against the onset of its tone burst in the file.

  obs-av.py FILE [--min-secs S] [--segments T1,T2,..]

Times are the file's own: the video frame's presentation time, and for
audio the decoded frame's presentation time plus the sample's place in it
(so AAC priming and any gap the muxer recorded count as they play).
Prints RESULT lines:
  flashes   flash frames found (luma) and how many have a burst within
            0.5 s, half the flash interval, so an offset of any size shows
            in "offset" (PASS: all but the first and last)
  video     frame intervals: count and largest gap (PASS: no interval over
            1.5 frame periods)
  offset    burst onset - flash frame: mean, std, min, max (PASS: |mean| <=
            45 ms, the ITU-R BT.1359 audio-lead detectability limit, and std
            <= 10 ms). OBS shows a source frame in the next frame of its own
            60 Hz canvas, and the two clocks differ a little, so the offset
            takes two values a frame period apart in changing proportion
  drift     slope of a line through the offsets, and the means per minute
            (PASS: the line moves less than one frame period over the run)
With --segments (seconds from the first video frame): per segment a line
  SEGMENT K START END flashes=N bursts=N first_flash=T last_flash=T
for the source-change check (live again after each change?).
"""
import argparse
import json
import subprocess
import sys

import numpy as np


def run(cmd):
    return subprocess.run(cmd, check=True, capture_output=True).stdout


def video(path):
    fr = json.loads(run(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
                         '-show_entries', 'frame=best_effort_timestamp_time',
                         '-of', 'json', path]))['frames']
    t = np.array([float(f['best_effort_timestamp_time']) for f in fr])
    raw = run(['ffmpeg', '-v', 'error', '-i', path, '-map', '0:v:0', '-fps_mode',
               'passthrough', '-vf', 'scale=32:18,format=gray', '-f', 'rawvideo', '-'])
    y = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 32 * 18).mean(axis=1)
    n = min(len(t), len(y))
    return t[:n], y[:n]


def audio(path):
    fr = json.loads(run(['ffprobe', '-v', 'error', '-select_streams', 'a:0',
                         '-show_entries', 'frame=pts_time,nb_samples', '-of', 'json',
                         path]))['frames']
    pts = np.array([float(f['pts_time']) for f in fr])
    ns = np.array([int(f['nb_samples']) for f in fr])
    raw = run(['ffmpeg', '-v', 'error', '-i', path, '-map', '0:a:0', '-f', 's16le',
               '-ac', '2', '-ar', '48000', '-'])
    s = np.frombuffer(raw, dtype=np.int16).reshape(-1, 2).astype(np.float32)
    start = np.concatenate([[0], np.cumsum(ns)[:-1]])
    return s, pts, start


def sample_time(i, pts, start, rate=48000):
    k = np.searchsorted(start, i, side='right') - 1
    return pts[k] + (i - start[k]) / rate


def onsets(s, rate=48000):
    """First sample of each burst: |left| + |right| over a threshold after
    at least 200 ms below it"""
    e = np.abs(s).sum(axis=1)
    thr = max(0.1 * e.max(), 500)
    idx = np.flatnonzero(e > thr)
    out = []
    last = -10 ** 9
    for i in idx:
        if i - last > rate // 5:
            out.append(i)
        last = i
    return np.array(out, dtype=np.int64)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('file')
    ap.add_argument('--min-secs', type=float, default=0)
    ap.add_argument('--segments', default='')
    a = ap.parse_args()
    ok = True

    def result(name, good, text):
        nonlocal ok
        ok &= good
        print(f"RESULT {name} {'PASS' if good else 'FAIL'} ({text})")

    vt, vy = video(a.file)
    s, apts, astart = audio(a.file)
    dur = vt[-1] - vt[0] if len(vt) > 1 else 0
    result('duration', dur >= a.min_secs, f'{dur:.1f} s of video, {len(s) / 48000:.1f} s of audio')
    d = np.diff(vt)
    per = float(np.median(d)) if len(d) else 0
    big = int(np.sum(d > 1.5 * per)) if per else 0
    result('video', per > 0 and big == 0,
           f'{len(vt)} frames, period {per * 1e3:.3f} ms, largest interval {d.max() * 1e3:.1f} ms, {big} over 1.5 periods')
    lo, hi = np.percentile(vy, 5), np.percentile(vy, 99.9)
    fl = np.flatnonzero(vy > (lo + hi) / 2)
    # one flash per run of bright frames: its first frame
    fl = fl[np.concatenate([[True], np.diff(fl) > 1])] if len(fl) else fl
    ft = vt[fl]
    on = onsets(s)
    bt = np.array([sample_time(i, apts, astart) for i in on])
    pairs = []
    for t in ft:
        if len(bt):
            j = int(np.argmin(np.abs(bt - t)))
            if abs(bt[j] - t) < 0.5:
                pairs.append((t, bt[j] - t))
    lone = [t - vt[0] for t in ft if not any(p[0] == t for p in pairs)]
    result('flashes', len(pairs) >= max(1, len(ft) - 2),
           f'{len(ft)} flash frames, {len(bt)} burst onsets, {len(pairs)} paired within 0.5 s' +
           (f"; unpaired at {', '.join(f'{x:.1f}' for x in lone[:10])} s" if lone else ''))
    if a.segments:
        end = vt[-1] - vt[0]
        edges = [0.0] + [float(x) for x in a.segments.split(',')] + [end]
        for k in range(len(edges) - 1):
            lo, hi = vt[0] + edges[k], vt[0] + edges[k + 1]
            f = ft[(ft >= lo) & (ft < hi)] - vt[0]
            b = bt[(bt >= lo) & (bt < hi)] - vt[0]
            print(f'SEGMENT {k} {edges[k]:.1f} {edges[k + 1]:.1f} flashes={len(f)} '
                  f'bursts={len(b)} first_flash={f"{f[0]:.2f}" if len(f) else "-"} '
                  f'last_flash={f"{f[-1]:.2f}" if len(f) else "-"}')
    if len(pairs) < 3:
        result('offset', False, 'too few flash/burst pairs')
        return 1
    t, off = (np.array(x) for x in zip(*pairs))
    m, sd = off.mean() * 1e3, off.std() * 1e3
    result('offset', abs(m) <= 45 and sd <= 10,
           f'burst onset - flash frame: mean {m:+.2f} ms, std {sd:.2f}, min {off.min() * 1e3:+.2f}, '
           f'max {off.max() * 1e3:+.2f} over {len(off)} flashes (positive: audio late)')
    mins = (t - t[0]) / 60
    slope = np.polyfit(mins, off * 1e3, 1)[0] if len(t) > 2 else 0
    total = slope * mins[-1]
    per_min = [off[(mins >= k) & (mins < k + 1)].mean() * 1e3
               for k in range(int(mins[-1]) + 1) if np.any((mins >= k) & (mins < k + 1))]
    result('drift', abs(total) < per * 1e3,
           f'{slope:+.3f} ms/min = {total:+.2f} ms over {mins[-1]:.1f} min (one frame period: '
           f'{per * 1e3:.1f} ms); means per minute ' + ' '.join(f'{x:+.1f}' for x in per_min))
    hist = np.round(off * 1e3 / per / 1e3).astype(int) if per else []
    if len(hist):
        u, c = np.unique(hist, return_counts=True)
        print('  offset in frame periods (count):', ', '.join(f'{x:+d}: {n}' for x, n in zip(u, c)))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
