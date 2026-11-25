#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Analyse a gc573-aud capture of tools/testsrc/avsync.sh (M4 gate).

live-av.py LOG RAW [--min-secs S] [--bursts] [--tail S]

LOG: gc573-aud -v output (A lines; V lines with -V); RAW: its -o samples
(S16_LE, 2 channels, 48 kHz). Prints RESULT lines (PASS/FAIL):

  duration   the capture lasted at least S seconds (default 0)
  xruns      gc573-aud reported no overrun
  rate       frames against CLOCK_MONOTONIC: within 0.05 % of 48 kHz
  gaps       no step in the frame/time line: the median of each second's
             read timestamps, against a straight line through all of them,
             stays within 3 ms (a lost or an inserted 10 ms period is a
             10 ms step; single reads may be late by IRQ latency)
  bursts     (with --bursts or V lines) a tone burst about once a second
  channels   per burst the dominant frequency: left 1 kHz, right 2 kHz,
             each within 1 % (a wrong rate or channel order shows here),
             and the other channel's tone at least 30 dB down
  tail       (with --tail S) the bursts of the last S seconds: one a
             second, each with the channels right (after a relock)
  video      with V lines: no sequence gap, frame intervals within 10 %
  avsync     with V lines: per flash (the first frame of each run of frames
             with mean luma > 128) the burst onset within 0.5 s; offset =
             onset time (ALSA timestamps, a line through the reads within
             1 s) - flash frame timestamp (vb2, end of frame). The source
             (ffplay) shows a flash a few whole frames early or late at
             times, so each offset is moved by whole frames to the nearest
             of the most common offset; both are reported. PASS if the
             corrected offsets stay within 1 ms of a line through them and
             that line moves less than one audio period (10 ms) over the run
"""
import re
import sys

import numpy as np

RATE = 48000


def result(name, ok, detail):
    print(f"RESULT {name:<10} {'PASS' if ok else 'FAIL'} ({detail})")
    return ok


def onsets_of(x):
    """First sample above 1/8 of full scale after >= 0.5 s of quiet."""
    env = np.abs(x).max(axis=1)
    loud = np.flatnonzero(env > 4096)
    out, last = [], -RATE
    for k in loud:
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
    log, raw = args
    a_hw, a_ts, v_seq, v_ts, v_y = [], [], [], [], []
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
        elif line.startswith('XRUN'):
            xruns += 1
    want_bursts |= bool(v_ts)
    a_hw = np.array(a_hw, dtype=np.float64)
    a_ts = np.array(a_ts, dtype=np.int64)
    x = np.fromfile(raw, dtype='<i2').reshape(-1, 2).astype(np.float64)
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
    step = (med.max() - med.min()) * 1e3 if len(med) else 0.0
    ok &= result('duration', secs >= min_secs,
                 f"{secs:.1f} s, {len(x)} frames, minimum {min_secs:.0f} s")
    ok &= result('xruns', xruns == 0, f"{xruns} overruns")
    ok &= result('rate', abs(rate / RATE - 1) < 5e-4,
                 f"{rate:.3f} Hz against CLOCK_MONOTONIC, {(rate / RATE - 1) * 1e6:+.1f} ppm")
    ok &= result('gaps', step < 3,
                 f"per-second medians within {step:.2f} ms, single reads within "
                 f"{np.abs(resid).max() * 1e3:.2f} ms of the line, {len(a_hw)} reads")

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
        seg = x[k:k + n]
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
    vbad = int(np.sum(np.abs(ivl / tf - 1) > 0.1))
    ok &= result('video', np.all(dseq == 1) and vbad == 0,
                 f"{len(v_seq)} frames, {int(np.sum(dseq != 1))} sequence gaps, "
                 f"interval {tf * 1e3:.3f} ms, {vbad} off by > 10 %")

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
    cl = np.round(offs / tfm).astype(int)
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
    ok &= result('avsync', res <= 1 and abs(drift) < 10,
                 f"{len(offs)} flashes over {span_min:.1f} min: offset {corr.mean():+.3f} ms "
                 f"(std {corr.std():.3f}, min {corr.min():+.3f}, max {corr.max():+.3f}), "
                 f"drift {dfit[0] * 60:+.4f} ms/min = {drift:+.3f} ms over the run, "
                 f"residual <= {res:.3f} ms")
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
