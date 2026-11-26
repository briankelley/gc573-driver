#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Analyse a gc573-aud capture of tools/testsrc/avsync.sh (M4 gate).

live-av.py LOG RAW [--min-secs S] [--bursts] [--tail S] [--segments T1,T2,..]
            [--exact counter|pattern RATE]

LOG: gc573-aud -v output (A lines; V lines with -V); RAW: its -o samples
(S16_LE, 2 channels, 48 kHz). Prints RESULT lines (PASS/FAIL):

  duration   the capture lasted at least S seconds (default 0)
  xruns      gc573-aud reported no overrun
  rate       frames against CLOCK_MONOTONIC: within 0.05 % of 48 kHz
  gaps       no step in the frame/time line: the median of each second's
             read timestamps, against a straight line through all of them,
             moves less than 3 ms from one second to the next (a lost or an
             inserted 10 ms period is a 10 ms step; single reads may be late
             by IRQ latency, and the line bends slowly where the clock's own
             rate changes, e.g. NTP after a boot: both reported)
  bursts     (with --bursts or V lines) a tone burst about once a second
  channels   per burst the dominant frequency: left 1 kHz, right 2 kHz,
             each within 1 % (a wrong rate or channel order shows here),
             and the other channel's tone at least 30 dB down
  tail       (with --tail S) the bursts of the last S seconds: one a
             second, each with the channels right (after a relock)
  video      with V lines: no sequence gap, every frame interval within
             half a period (a lost or doubled frame fails; intervals more
             than 10 % off, IRQ latency, are reported)
  avsync     with V lines: per flash (the first frame of each run of frames
             with mean luma > 128) the burst onset within 0.5 s; offset =
             onset time (ALSA timestamps, a line through the reads within
             1 s) - flash frame timestamp (vb2, end of frame). The source
             (ffplay) shows a flash a few whole frames early or late at
             times, so each offset is moved by whole frames to the nearest
             of the most common offset; both are reported. PASS if the
             corrected offsets stay within 1 ms of a line through them and
             that line moves less than one audio period (10 ms) over the run
--segments (seconds from the first read): per segment a line
  SEGMENT K START END pairs=N raw=MS min=MS max=MS frames=CLUSTERS corr=MS
with the raw offsets of the flashes in it and their mean moved by whole
frames as for avsync (corr), for captures across source changes (does the
offset stay where it was?)
With counters (gc573-aud -V -P: the picture of avsync.sh --pattern or show.sh
--counter, V lines with c=N and the flash box's luma as y), two INFO lines:
  counter    the counter's step from each captured frame to the next (1:
             each source frame captured once; 0: one twice; 2 or more:
             frames never captured), over frames without a sequence gap,
             and the frames whose counter was unreadable (torn or blended)
  flashes    the source's flash frames (every N-th counter value) between
             the first and the last frame: captured once, twice or more,
             never (a flash missing from the capture), and the frames whose
             flash box disagrees with their counter
They describe the source (the test player's pacing on the host's display)
as much as the capture: the driver's own losses are the sequence gaps.
--exact KIND RATE (with counters; KIND: counter for show.sh --counter,
whose player is paced by the system clock, pattern for avsync.sh
--pattern, paced by the HDMI audio clock; RATE: 60 or 59.94) tells the
two apart:
  exact      the driver lost nothing: no sequence gap, and every frame
             interval between half and one and a half periods (PASS)
  INFO source  the source's slips: counter repeats, skips and tears
             (unreadable counters) between frames at regular intervals,
             and how they cluster; their net (source frames advanced less
             frames captured) against the clocks' prediction, (source
             rate - capture rate) x duration. The capture rate is the
             frames' own (a line through their timestamps, CLOCK_MONOTONIC);
             the source's is RATE (60000/1001 for 59.94) on the system
             clock, or times the audio rate over 48 kHz (the bursts' clock,
             measured here) for pattern. A player shows a frame twice or
             skips one when its frame times cross the display's refresh, in
             a cluster while they stay within about 2 ms of it. The source
             is flagged BROKEN when the net misses the prediction by more
             than 1.5 frames, or the clusters are more than the crossings
             the clocks allow (the whole number above duration x rate
             difference, plus one)
Without counters (plain avsync.sh, the whole frame flashes) one INFO line:
  flashes    runs of flash frames (mean luma over 128) by length, frames
             partly white (luma 48 to 208 at a flash: a torn or blended
             frame), and flashes missing (onsets 1.5 or more intervals
             apart)
"""
import re
import sys

import numpy as np

RATE = 48000


def result(name, ok, detail):
    print(f"RESULT {name:<10} {'PASS' if ok else 'FAIL'} ({detail})")
    return ok


def counters(seq, c, hot):
    """INFO counter and INFO flashes (see the top) from the frames' sequence
    numbers, counters (-1: unreadable) and flash boxes"""
    dseq = np.diff(seq)
    good = np.flatnonzero(c >= 0)
    if len(good) < 2:
        print(f"INFO counter   {len(c)} frames, {len(good)} with a readable counter")
        return
    step = (c[good[1:]] - c[good[:-1]]) % 65536
    adjacent = good[1:] - good[:-1] == 1
    nogap = np.array([np.all(dseq[a:b] == 1) for a, b in zip(good[:-1], good[1:])])
    st = step[adjacent & nogap]
    vals, cnt = np.unique(st, return_counts=True)
    lost = int(np.sum(st[st > 1] - 1))
    print(f"INFO counter   {len(c)} frames, {len(c) - len(good)} unreadable; steps from one "
          f"frame to the next (step: count) " + ', '.join(f'{v}: {n}' for v, n in zip(vals, cnt)) +
          f"; {int(np.sum(st == 0))} repeated, {lost} source frames never captured")
    # the counter unwrapped (16 bits), over the readable frames
    u = np.zeros(len(c), dtype=np.int64) - 1
    u[good[0]] = c[good[0]]
    u[good[1:]] = c[good[0]] + np.cumsum(step)
    hu = np.unique(u[good][hot[good]])
    d = np.diff(hu)
    d = d[d > 1]
    if not len(d):
        print("INFO flashes   no flash box seen twice")
        return
    dv, dc = np.unique(d, return_counts=True)
    n = int(dv[np.argmax(dc)])
    lo, hi = u[good[0]], u[good[-1]]
    want = np.arange((lo + n - 1) // n * n, hi + 1, n)
    seen = u[good]
    times = np.array([np.sum(seen == w) for w in want])
    # a flash frame from the counter's view: its multiples of n; the box
    # must agree on every readable frame
    off = int(np.sum((seen % n == 0) != hot[good]))
    print(f"INFO flashes   every {n} frames, {len(want)} between the first and last frame: "
          f"{int(np.sum(times == 1))} captured once, {int(np.sum(times == 2))} twice, "
          f"{int(np.sum(times > 2))} more often, {int(np.sum(times == 0))} never; "
          f"{off} frames whose flash box disagrees with the counter")


def exact_check(exact, seq, ts, c, arate):
    """RESULT exact and INFO source (--exact, see the top)"""
    kind, nominal = exact
    f_nom = 60000 / 1001 if nominal == '59.94' else float(nominal)
    seq = np.asarray(seq)
    ts = np.asarray(ts, dtype=np.int64)
    t = (ts - ts[0]) / 1e9
    dseq = np.diff(seq)
    ivl = np.diff(t)
    period = np.polyfit(seq - seq[0], t, 1)[0]		# s per frame, by the sequence
    f_cap = 1 / period
    gaps = int(np.sum(dseq != 1))
    long_ = int(np.sum(ivl > 1.5 * period))
    short = int(np.sum(ivl < 0.5 * period))
    ok = gaps == 0 and long_ == 0 and short == 0
    result('exact', ok, f"the driver: {gaps} sequence gaps, {long_} frame intervals over 1.5 periods, "
                        f"{short} under half a period, over {len(seq)} frames at {f_cap:.5f} Hz")
    # the source: steps between readable frames at regular intervals
    regular = (dseq == 1) & (ivl >= 0.5 * period) & (ivl <= 1.5 * period)
    rd = c >= 0
    ev = []		# (time, kind, frames)
    for i in np.flatnonzero(regular & rd[:-1] & rd[1:]):
        st = int((c[i + 1] - c[i]) % 65536)
        if st == 0:
            ev.append((t[i + 1], 'repeat', 1))
        elif st > 1:
            ev.append((t[i + 1], 'skip', st - 1))
    for i in np.flatnonzero(~rd):
        if 0 < i < len(c) - 1 and regular[i - 1] and regular[i]:
            ev.append((t[i], 'tear', 1))
    ev.sort()
    good = np.flatnonzero(rd)
    if len(good) < 2:
        print(f"INFO source    {len(good)} readable counters: no slips to judge")
        return ok
    step = (c[good[1:]] - c[good[:-1]]) % 65536
    advanced = int(np.sum(step))
    captured = int(seq[good[-1]] - seq[good[0]])
    net = advanced - captured
    secs = t[good[-1]] - t[good[0]]
    if kind == 'pattern':
        f_src = f_nom * arate / RATE
        how = f'{f_nom:.5f} Hz x {arate:.3f}/48000 (the HDMI audio clock)'
    else:
        f_src = f_nom
        how = f'{f_nom:.5f} Hz (the system clock)'
    df = f_src - f_cap
    pred = df * secs
    # one crossing every 1/|df| s; the frame times stay within J of the
    # refresh for J x f_cap / |df| s: events closer than that are one
    J = 2e-3
    span = J * f_cap / abs(df) if df else secs
    span = max(2.0, min(span, secs))
    clusters = []
    for x in ev:
        if clusters and x[0] - clusters[-1][1] <= span:
            clusters[-1][1] = x[0]
            clusters[-1][2].append(x)
        else:
            clusters.append([x[0], x[0], [x]])
    allowed = int(np.ceil(abs(pred))) + 1
    broken = abs(net - pred) > 1.5 or len(clusters) > allowed
    n = {k: sum(f for _, kk, f in ev if kk == k) for k in ('repeat', 'skip', 'tear')}
    desc = '; '.join(f"{a:.1f}-{b:.1f} s: " + ', '.join(f"{sum(f for _, kk, f in e if kk == k)} {k}"
                                                         for k in ('repeat', 'skip', 'tear')
                                                         if any(kk == k for _, kk, _f in e))
                     for a, b, e in clusters)
    print(f"INFO source    {n['repeat']} frames shown twice, {n['skip']} skipped, {n['tear']} torn, between "
          f"frames at regular intervals; net {net:+d} frames over {secs:.1f} s (source frames advanced "
          f"{advanced}, captured {captured}); the clocks predict {pred:+.2f} (source {how} = "
          f"{f_src:.5f} Hz, capture {f_cap:.5f} Hz, a crossing every "
          f"{(1 / abs(df) if df else float('inf')):.0f} s); {len(clusters)} clusters (at most {allowed}, "
          f"events within {span:.1f} s as one){': ' + desc if desc else ''}; "
          + ('SOURCE BROKEN: more slips than its clock explains' if broken else 'explained by the clocks'))
    return ok


def flash_runs(y):
    """INFO flashes for a capture without counters (see the top)"""
    hot = y > 128
    part = (y >= 48) & (y <= 208)
    edges = np.flatnonzero(np.diff(np.concatenate(([0], hot.astype(int), [0]))))
    starts, ends = edges[::2], edges[1::2]
    if len(starts) < 2:
        print(f"INFO flashes   {len(starts)} flashes")
        return
    lens, cnt = np.unique(ends - starts, return_counts=True)
    gap = np.diff(starts)
    n = int(np.median(gap))
    missing = int(np.sum(np.round(gap[gap >= 1.5 * n] / n) - 1))
    print(f"INFO flashes   {len(starts)} flashes every {n} frames, by length (frames: count) " +
          ', '.join(f'{v}: {c}' for v, c in zip(lens, cnt)) +
          f"; {int(np.sum(part))} frames partly white; {missing} missing")


def onsets_of(x):
    """First sample above 1/8 of full scale after >= 0.5 s of quiet. In
    chunks: x may be a memory map of hours of samples."""
    out, last, step = [], -RATE, 1 << 22
    for c in range(0, len(x), step):
        env = np.abs(x[c:c + step].astype(np.int32)).max(axis=1)
        for k in np.flatnonzero(env > 4096) + c:
            if k - last > RATE // 2:
                out.append(int(k))
            last = k
    return out


def main():
    args = sys.argv[1:]
    min_secs, want_bursts, tail = 0.0, False, 0.0
    if '--min-secs' in args:
        i = args.index('--min-secs')
        min_secs = float(args[i + 1])
        del args[i:i + 2]
    if '--tail' in args:
        i = args.index('--tail')
        tail = float(args[i + 1])
        del args[i:i + 2]
    if '--bursts' in args:
        args.remove('--bursts')
        want_bursts = True
    exact = None
    if '--exact' in args:
        i = args.index('--exact')
        exact = (args[i + 1], args[i + 2])
        del args[i:i + 3]
    segments = []
    if '--segments' in args:
        i = args.index('--segments')
        segments = [float(v) for v in args[i + 1].split(',') if v]
        del args[i:i + 2]
    log, raw = args
    a_hw, a_ts, v_seq, v_ts, v_y, v_c = [], [], [], [], [], []
    xruns = 0
    for line in open(log):
        if line.startswith('A '):
            m = re.search(r'hw=(\d+) ts_ns=(\d+)', line)
            a_hw.append(int(m.group(1)))
            a_ts.append(int(m.group(2)))
        elif line.startswith('V '):
            m = re.search(r'seq=(\d+) ts_ns=(\d+) y=(\d+)', line)
            v_seq.append(int(m.group(1)))
            v_ts.append(int(m.group(2)))
            v_y.append(int(m.group(3)))
            m = re.search(r' c=(-?\d+)', line)
            if m:
                v_c.append(int(m.group(1)))
        elif line.startswith('XRUN'):
            xruns += 1
    want_bursts |= bool(v_ts)
    a_hw = np.array(a_hw, dtype=np.float64)
    a_ts = np.array(a_ts, dtype=np.int64)
    x = np.memmap(raw, dtype='<i2', mode='r').reshape(-1, 2)
    ok = True

    t0 = a_ts[0]
    at = (a_ts - t0) / 1e9			# seconds since the first read
    secs = at[-1]
    rate = (a_hw[-1] - a_hw[0]) / secs if secs > 0 else 0
    fit = np.polyfit(a_hw, at, 1)
    resid = at - np.polyval(fit, a_hw)
    per_s = max(1, int(len(at) / secs)) if secs > 0 else 1
    med = np.array([np.median(resid[i:i + per_s])
                    for i in range(0, len(resid) - per_s + 1, per_s)])
    bend = (med.max() - med.min()) * 1e3 if len(med) else 0.0
    step = np.abs(np.diff(med)).max() * 1e3 if len(med) > 1 else 0.0
    ok &= result('duration', secs >= min_secs,
                 f"{secs:.1f} s, {len(x)} frames, minimum {min_secs:.0f} s")
    ok &= result('xruns', xruns == 0, f"{xruns} overruns")
    ok &= result('rate', abs(rate / RATE - 1) < 5e-4,
                 f"{rate:.3f} Hz against CLOCK_MONOTONIC, {(rate / RATE - 1) * 1e6:+.1f} ppm")
    ok &= result('gaps', step < 3,
                 f"per-second medians move <= {step:.2f} ms from one second to the next; "
                 f"within {bend:.2f} ms of one line over the run; single reads within "
                 f"{np.abs(resid).max() * 1e3:.2f} ms of it; {len(a_hw)} reads")

    onsets = onsets_of(x)
    if want_bursts:
        span = len(x) / RATE
        ok &= result('bursts', abs(len(onsets) - span) <= 1.5,
                     f"{len(onsets)} in {span:.1f} s")

    # dominant frequency per channel over one 60 Hz frame from the onset
    bad, worst, xtalk, fl, fr, good = 0, 0.0, -np.inf, [], [], []
    n, nfft = 800, 1 << 16
    f = np.fft.rfftfreq(nfft, 1 / RATE)
    i1, i2 = np.argmin(np.abs(f - 1000)), np.argmin(np.abs(f - 2000))
    for k in onsets:
        seg = x[k:k + n].astype(np.float64)
        if len(seg) < n:
            continue
        w = np.hanning(n)
        spec = [np.abs(np.fft.rfft(seg[:, c] * w, nfft)) for c in (0, 1)]
        peak = [f[np.argmax(s)] for s in spec]
        fl.append(peak[0])
        fr.append(peak[1])
        xt = max(20 * np.log10(spec[0][i2] / spec[0][i1]),
                 20 * np.log10(spec[1][i1] / spec[1][i2]))
        xtalk = max(xtalk, xt)
        err = max(abs(peak[0] / 1000 - 1), abs(peak[1] / 2000 - 1))
        worst = max(worst, err)
        good.append((k, err <= 0.01 and xt <= -30))
        if err > 0.01 or xt > -30:
            bad += 1
    if tail:
        last = [g for k, g in good if k >= len(x) - tail * RATE]
        ok &= result('tail', len(last) >= tail - 1.5 and all(last),
                     f"{len(last)} bursts in the last {tail:.0f} s, "
                     f"{sum(1 for g in last if not g)} with the channels wrong")
    if want_bursts:
        if fl:
            ok &= result('channels', bad == 0,
                         f"left {np.mean(fl):.1f} Hz, right {np.mean(fr):.1f} Hz over "
                         f"{len(fl)} bursts, worst {worst * 100:.2f} % off, other tone "
                         f"<= {xtalk:.1f} dB, {bad} bad")
        else:
            ok &= result('channels', False, "no burst")

    if not v_ts:
        return 0 if ok else 1

    v_seq = np.array(v_seq)
    v_ts = np.array(v_ts, dtype=np.int64)
    v_y = np.array(v_y)
    dseq = np.diff(v_seq)
    ivl = np.diff(v_ts) / 1e9
    tf = float(np.median(ivl))
    vhalf = int(np.sum(np.abs(ivl / tf - 1) > 0.5))
    vbad = int(np.sum(np.abs(ivl / tf - 1) > 0.1))
    ok &= result('video', np.all(dseq == 1) and vhalf == 0,
                 f"{len(v_seq)} frames, {int(np.sum(dseq != 1))} sequence gaps, "
                 f"interval {tf * 1e3:.3f} ms, {vhalf} off by more than half a period, "
                 f"{vbad} by more than 10 %")
    if len(v_c) == len(v_seq):
        counters(v_seq, np.array(v_c), v_y > 128)
        if exact:
            ok &= exact_check(exact, v_seq, v_ts, np.array(v_c), rate)
    else:
        flash_runs(v_y)
        if exact:
            ok &= result('exact', False, 'no counters in the capture (gc573-aud -P)')

    hot = v_y > 128
    first = np.flatnonzero(hot & ~np.concatenate(([False], hot[:-1])))
    flash = (v_ts[first] - t0) / 1e9
    on_hw = np.array(onsets, dtype=np.float64)
    on_t = []
    for k in on_hw:
        lo, hi = np.searchsorted(a_hw, [k - RATE, k + RATE])
        if hi - lo < 10:
            lo, hi = 0, len(a_hw)
        lf = np.polyfit(a_hw[lo:hi], at[lo:hi], 1)
        on_t.append(np.polyval(lf, k))
    on_t = np.array(on_t)
    offs, when = [], []
    for t in flash:
        if len(on_t) == 0:
            break
        j = np.argmin(np.abs(on_t - t))
        if abs(on_t[j] - t) < 0.5:
            offs.append((on_t[j] - t) * 1e3)
            when.append(t)
    if len(offs) < 2:
        ok &= result('avsync', False,
                     f"{len(flash)} flashes, {len(onsets)} bursts: no pairs")
        return 0 if ok else 1
    offs, when = np.array(offs), np.array(when)
    tfm = tf * 1e3
    # whole frames from the median: rounding offs / tfm itself splits a
    # tight set of offsets near half a period into two classes a frame
    # apart (the 2 h host soak's last session: +8.21 to +8.82 ms at
    # 16.683 ms, "corrected" to a 17 ms spread)
    med = float(np.median(offs))
    cl = np.round((offs - med) / tfm).astype(int)
    vals, cnt = np.unique(cl, return_counts=True)
    ref = vals[np.argmax(cnt)]
    corr = offs - (cl - ref) * tfm
    span_min = (when[-1] - when[0]) / 60
    dfit = np.polyfit(when - when[0], corr, 1)
    res = np.abs(corr - np.polyval(dfit, when - when[0])).max()
    drift = dfit[0] * (when[-1] - when[0])
    clusters = ', '.join(f"{(v - ref):+d}: {c}" for v, c in zip(vals, cnt))
    print(f"  raw offsets: mean {offs.mean():+.2f} ms, min {offs.min():+.2f}, max "
          f"{offs.max():+.2f}, std {offs.std():.2f}; frames from the most common "
          f"(count): {clusters}")
    if segments:
        edges = [0.0] + segments + [float(at[-1])]
        for k in range(len(edges) - 1):
            m = (when >= edges[k]) & (when < edges[k + 1])
            if not np.any(m):
                print(f"SEGMENT {k} {edges[k]:.1f} {edges[k + 1]:.1f} pairs=0")
                continue
            o = offs[m]
            sv, sc = np.unique(np.round((o - med) / tfm).astype(int), return_counts=True)
            print(f"SEGMENT {k} {edges[k]:.1f} {edges[k + 1]:.1f} pairs={len(o)} raw={o.mean():+.2f} "
                  f"min={o.min():+.2f} max={o.max():+.2f} frames=" +
                  ','.join(f'{v - ref:+d}:{c}' for v, c in zip(sv, sc)) + f" corr={corr[m].mean():+.3f}")
    ok &= result('avsync', res <= 1 and abs(drift) < 10,
                 f"{len(offs)} flashes over {span_min:.1f} min: offset {corr.mean():+.3f} ms "
                 f"(std {corr.std():.3f}, min {corr.min():+.3f}, max {corr.max():+.3f}), "
                 f"drift {dfit[0] * 60:+.4f} ms/min = {drift:+.3f} ms over the run, "
                 f"residual <= {res:.3f} ms")
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
