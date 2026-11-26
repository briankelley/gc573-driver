#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""A/V offset in a recording of tools/testsrc/avsync.sh (an OBS recording
of the GC573 sources, tests/live.sh step obsav): the time of each flash
frame in the file against the onset of its tone burst in the file.

  obs-av.py FILE [--min-secs S] [--segments T1,T2,..] [--box X0,Y0,X1,Y1] [--ref MS]

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
            (PASS: the line moves less than one frame period over the run;
            SKIP under 5 min: OBS's canvas beats against the source's rate,
            which steps the offset by a frame period every few minutes)
--ref MS: the source's own offset in this avsync.sh session, measured with
the driver's timestamps just before (tests/live.sh step obsav). The source's
offset depends on the host's audio path and changes from one session to the
next (PipeWire backend: +24 to +45 ms, audio late), so "offset" then judges
the recording's mean minus MS, OBS's own part, against the same limits.
--box: the flash is a box at these fractions of the frame (avsync.sh
--pattern: 0.70,0.88,0.92,0.92), not the whole frame.
  audio-timeline  the bursts' intervals in the file, per source session
            (from where the pairs come back after a change, + 3 s): each a
            whole number of media periods (n/fps: 1 s at 60 Hz, 1.001 s at
            59.94) within 4 ms. OBS lays an ALSA source's samples back to
            back while their timestamps stay within 70 ms of where it
            expects them (libobs TS_SMOOTHING_THRESHOLD), so the bursts keep
            the media period exactly, while the source's audio clock runs
            against the host's (the HDMI audio clock, about +25 ppm here)
            and OBS's own A/V offset grows by that difference. Once it is
            70 ms, libobs places a packet at its own timestamp again: 70 ms
            of audio are overwritten, and one interval comes 70 ms short (a
            reset, reported; at 60 to 80 ms short). Any other interval off
            the media period FAILs: audio lost or added in a session, which
            the driver must not do (its stream keeps time through input
            changes). Per session a line
  AUDIO K P=S bursts=N ppm=+X resets=T:MS,.. other=T:MS,..
            (ppm: the bursts' period against the media period; 0 when OBS
            lays the samples back to back)
With --segments (seconds from the first video frame): per segment a line
  SEGMENT K START END flashes=N bursts=N back=+S pairs_after=N offset=MS ok
(back: where flashes and bursts pair again after the change) and a RESULT
segments line: each segment paired again, with at least every other
second's flash paired from there (OBS without buffering drops a one-frame
flash at times), and a mean offset within ITU-R BT.1359's detectability
limits, audio at most 45 ms early and 125 ms late; flashes, offset and
drift are then not judged over the whole file (the source restarts at each
change, with an offset of its own).
"""
import argparse
import json
import subprocess
import sys

import numpy as np


def run(cmd):
    return subprocess.run(cmd, check=True, capture_output=True).stdout


def video(path, box=None):
    """Each frame's presentation time and mean luma (of the box). The times
    come from the packets, sorted (no decode: a second decode of a 2-hour
    recording would double the time), unless their count differs from the
    decoded frames'; then from ffprobe's frames"""
    vf = 'scale=32:18,format=gray'
    if box:
        x0, y0, x1, y1 = box
        vf = f'crop=iw*{x1 - x0}:ih*{y1 - y0}:iw*{x0}:ih*{y0},' + vf
    raw = run(['ffmpeg', '-v', 'error', '-i', path, '-map', '0:v:0', '-fps_mode',
               'passthrough', '-vf', vf, '-f', 'rawvideo', '-'])
    y = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 32 * 18).mean(axis=1)
    t = np.sort(np.array([float(v) for v in run(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
                                                  '-show_entries', 'packet=pts_time', '-of', 'csv=p=0',
                                                  path]).split() if v and v != b'N/A']))
    if len(t) != len(y):
        fr = json.loads(run(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
                             '-show_entries', 'frame=best_effort_timestamp_time',
                             '-of', 'json', path]))['frames']
        t = np.array([float(f['best_effort_timestamp_time']) for f in fr])
    n = min(len(t), len(y))
    return t[:n], y[:n]


def envelopes(path, chunk=48000 * 60):
    """|left| + |right| of the decoded audio, a minute at a time (a 2-hour
    recording is 1.4 GB of samples: never all in memory)"""
    p = subprocess.Popen(['ffmpeg', '-v', 'error', '-i', path, '-map', '0:a:0', '-f', 's16le',
                          '-ac', '2', '-ar', '48000', '-'], stdout=subprocess.PIPE)
    while True:
        b = p.stdout.read(chunk * 4)
        if not b:
            break
        x = np.frombuffer(b[:len(b) // 4 * 4], dtype=np.int16).reshape(-1, 2).astype(np.int32)
        yield np.abs(x).sum(axis=1)
    p.wait()


def audio(path):
    """Sample count, burst onsets (sample indices), and each decoded frame's
    presentation time and first sample"""
    fr = json.loads(run(['ffprobe', '-v', 'error', '-select_streams', 'a:0',
                         '-show_entries', 'frame=pts_time,nb_samples', '-of', 'json',
                         path]))['frames']
    pts = np.array([float(f['pts_time']) for f in fr])
    ns = np.array([int(f['nb_samples']) for f in fr])
    start = np.concatenate([[0], np.cumsum(ns)[:-1]])
    peak = max((int(e.max()) for e in envelopes(path) if len(e)), default=0)
    n, on = 0, []
    thr, last = max(0.1 * peak, 500), -10 ** 9
    for e in envelopes(path):
        for i in np.flatnonzero(e > thr) + n:
            if i - last > 48000 // 5:
                on.append(int(i))
            last = i
        n += len(e)
    return n, np.array(on, dtype=np.int64), pts, start


def sample_time(i, pts, start, rate=48000):
    k = np.searchsorted(start, i, side='right') - 1
    return pts[k] + (i - start[k]) / rate


def timeline(bt, spans):
    """[(K, media period, bursts, ppm, resets, other)] for each span (K,
    t0, t1) of burst times BT (s): the media period (1 s or 1.001 s, by
    the median interval), the bursts' period against it over the regular
    intervals (ppm), and the intervals off a whole number of media periods
    by 4 ms or more, as (time, deviation in ms): resets (60 to 80 ms short:
    libobs placing a packet at its own timestamp again) and other"""
    out = []
    for k, t0, t1 in spans:
        b = bt[(bt >= t0) & (bt < t1)]
        if len(b) < 10:
            continue
        P = 1.001 if abs(float(np.median(np.diff(b))) - 1.001) < 0.0005 else 1.0
        n = np.round(np.diff(b) / P)
        d = np.diff(b) - P * n
        reg = np.abs(d) < 0.004
        ppm = float(d[reg].sum() / (P * n[reg].sum()) * 1e6) if n[reg].sum() else 0.0
        odd = [(float(b[i + 1]), float(d[i] * 1e3)) for i in np.flatnonzero(~reg)]
        resets = [x for x in odd if -80 <= x[1] <= -60]
        other = [x for x in odd if not -80 <= x[1] <= -60]
        out.append((k, P, len(b), ppm, resets, other))
    return out


def timeline_result(result, tl):
    """the AUDIO lines and RESULT audio-timeline from timeline()'s list"""
    for k, P, n, ppm, resets, other in tl:
        print(f'AUDIO {k} P={P:.3f} bursts={n} ppm={ppm:+.2f} '
              f'resets={",".join(f"{t:.1f}:{x:+.1f}" for t, x in resets) or "-"} '
              f'other={",".join(f"{t:.1f}:{x:+.1f}" for t, x in other) or "-"}')
    if not tl:
        print('RESULT audio-timeline SKIP (no source session with 10 bursts or more)')
        return
    allr = [x for *_, r, _o in tl for x in r]
    allo = [x for *_, o in tl for x in o]
    ppms = [x[3] for x in tl]
    result('audio-timeline', not allo,
           f'{len(tl)} source session{"s" if len(tl) > 1 else ""}: the bursts\' period against the media '
           f'period {min(ppms):+.2f} to {max(ppms):+.2f} ppm (0: OBS lays the samples back to back); '
           f'OBS\'s own resets at its 70 ms threshold: {len(allr)}'
           + (f" ({', '.join(f'{t:.1f} s {x:+.1f} ms' for t, x in allr)})" if allr else '')
           + (f"; other intervals off the media period: "
              f"{', '.join(f'{t:.1f} s {x:+.1f} ms' for t, x in allo[:10])}" if allo else ''))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('file')
    ap.add_argument('--min-secs', type=float, default=0)
    ap.add_argument('--segments', default='')
    ap.add_argument('--box', default='')
    ap.add_argument('--ref', type=float, default=None)
    a = ap.parse_args()
    ok = True

    def result(name, good, text):
        nonlocal ok
        ok &= good
        print(f"RESULT {name} {'PASS' if good else 'FAIL'} ({text})")

    vt, vy = video(a.file, [float(x) for x in a.box.split(',')] if a.box else None)
    nsamp, on, apts, astart = audio(a.file)
    dur = vt[-1] - vt[0] if len(vt) > 1 else 0
    result('duration', dur >= a.min_secs, f'{dur:.1f} s of video, {nsamp / 48000:.1f} s of audio')
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
    bt = np.array([sample_time(i, apts, astart) for i in on])
    pairs = []
    for t in ft:
        if len(bt):
            j = int(np.argmin(np.abs(bt - t)))
            if abs(bt[j] - t) < 0.5:
                pairs.append((t, bt[j] - t))
    lone = [t - vt[0] for t in ft if not any(p[0] == t for p in pairs)]
    result('flashes', len(pairs) >= max(1, len(ft) - 2) or bool(a.segments),
           f'{len(ft)} flash frames, {len(bt)} burst onsets, {len(pairs)} paired within 0.5 s' +
           (f"; unpaired at {', '.join(f'{x:.1f}' for x in lone[:10])} s" if lone else ''))
    if a.segments:
        # Per segment (from one change to the next): where the pictures and
        # sound come back paired (the pair after the longest gap between
        # pairs, counted from the segment's start), and from there at least
        # every other second's flash paired, with a mean offset from -45 to
        # +125 ms. The source restarts at each change with an offset of its own
        end = vt[-1] - vt[0]
        edges = [0.0] + [float(x) for x in a.segments.split(',')] + [end]
        bad_segs, rec, spans = [], [], []
        for k in range(len(edges) - 1):
            lo, hi = vt[0] + edges[k], vt[0] + edges[k + 1]
            f = ft[(ft >= lo) & (ft < hi)] - vt[0]
            b = bt[(bt >= lo) & (bt < hi)] - vt[0]
            pk = [(t - vt[0], o) for t, o in pairs if lo <= t < hi]
            back = None
            if pk:
                times = [edges[k]] + [t for t, _ in pk]
                g = int(np.argmax(np.diff(times)))
                back = times[g + 1]
                pk = [x for x in pk if x[0] >= back]
            po = [o for _, o in pk]
            steady = edges[k + 1] - back if back is not None else 0
            good = bool(pk) and len(pk) >= steady / 2 and -45 <= np.mean(po) * 1e3 <= 125
            if k > 0 and back is not None:
                rec.append(back - edges[k])
            # the audio timeline from 15 s after the change (the source has
            # restarted by then), whether or not flashes pair yet
            spans.append((k, vt[0] + edges[k] + (15 if k else 3), vt[0] + edges[k + 1] - 1))
            if not good:
                bad_segs.append(k)
            print(f'SEGMENT {k} {edges[k]:.1f} {edges[k + 1]:.1f} flashes={len(f)} bursts={len(b)} '
                  f'back={f"+{back - edges[k]:.2f}" if back is not None else "-"} pairs_after={len(po)} '
                  f'offset={f"{np.mean(po) * 1e3:+.1f}" if po else "-"} {"ok" if good else "NOT OK"}')
        timeline_result(result, timeline(bt - vt[0], [(k, a0 - vt[0], a1 - vt[0]) for k, a0, a1 in spans]))
        result('segments', not bad_segs,
               f'{len(edges) - 1} segments between changes, each paired again, with at least every other '
               f'second\'s flash paired from there and a mean offset from -45 to +125 ms (BT.1359)' +
               (f'; not: segments {", ".join(map(str, bad_segs))}' if bad_segs else '') +
               (f'; paired again after a change: median +{np.median(rec):.2f} s, max +{max(rec):.2f} s '
                f'from the change' if rec else ''))
    if not a.segments:
        # one source session: from 3 s in to 1 s before the end
        timeline_result(result, timeline(bt - vt[0], [(0, 3.0, vt[-1] - vt[0] - 1)]))
    if len(pairs) < 3:
        result('offset', False, 'too few flash/burst pairs')
        return 1
    t, off = (np.array(x) for x in zip(*pairs))
    m, sd = off.mean() * 1e3, off.std() * 1e3
    own = m - a.ref if a.ref is not None else m
    text = (f'burst onset - flash frame: mean {m:+.2f} ms, std {sd:.2f}, min {off.min() * 1e3:+.2f}, '
            f'max {off.max() * 1e3:+.2f} over {len(off)} flashes (positive: audio late)'
            + (f'; the source\'s own {a.ref:+.2f} ms taken out: OBS {own:+.2f} ms' if a.ref is not None else ''))
    if a.segments:
        # one source session per segment, each with an offset of its own:
        # the segments are judged one by one above
        print(f'RESULT offset SKIP ({text}; over all segments)')
    else:
        result('offset', abs(own) <= 45 and sd <= 10, text)
    mins = (t - t[0]) / 60
    slope = np.polyfit(mins, off * 1e3, 1)[0] if len(t) > 2 else 0
    total = slope * mins[-1]
    per_min = [off[(mins >= k) & (mins < k + 1)].mean() * 1e3
               for k in range(int(mins[-1]) + 1) if np.any((mins >= k) & (mins < k + 1))]
    text = (f'{slope:+.3f} ms/min = {total:+.2f} ms over {mins[-1]:.1f} min (one frame period: '
            f'{per * 1e3:.1f} ms); means per minute ' + ' '.join(f'{x:+.1f}' for x in per_min))
    if a.segments:
        print(f'RESULT drift SKIP ({text}; the source restarts at each change)')
    elif mins[-1] < 5:
        # OBS shows each source frame in the next frame of its own 60 Hz
        # canvas: the offset steps by a frame period as the two rates beat
        # (60.006 against 60.000 Hz on the loopback: about every 2.8 min),
        # so a line through a shorter run measures where in that cycle it
        # fell, not drift
        print(f'RESULT drift SKIP ({text}; under 5 min, shorter than two cycles of the canvas beat)')
    else:
        result('drift', abs(total) < per * 1e3, text)
    hist = np.round(off * 1e3 / per / 1e3).astype(int) if per else []
    if len(hist):
        u, c = np.unique(hist, return_counts=True)
        print('  offset in frame periods (count):', ', '.join(f'{x:+d}: {n}' for x, n in zip(u, c)))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
