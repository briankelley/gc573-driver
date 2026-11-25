#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Per-frame report for gc573-cap -F output (stdin): for each capture run (the
# FRAME lines before each "RESULT capture" line) prints the frames whose
# full-frame signature differs from the run's most common one, and the
# intervals more than 5 % away from the median, with the frame index and the
# time from the run's first frame. Prints nothing for a clean run.
# Usage: gc573-cap ... -F | tests/frame-report.py
import re
import sys
from collections import Counter


def report(fmt, frames):
    if not frames:
        return
    common = Counter(f[2] for f in frames).most_common(1)[0][0]
    ivls = sorted(b[1] - a[1] for a, b in zip(frames, frames[1:]))
    med = ivls[len(ivls) // 2] if ivls else 0
    t0 = frames[0][1]
    odd = []
    for i, (seq, ts, sig) in enumerate(frames):
        d = ts - frames[i - 1][1] if i else med
        diff = sig != common
        if diff or (med and abs(d - med) > 0.05 * med):
            odd.append('#%d seq %d at %.1f ms, interval %.3f ms%s'
                       % (i, seq, ts - t0, d, ', DIFFERENT' if diff else ''))
    if odd:
        print('frames %s: %d of %d irregular (median interval %.3f ms): %s'
              % (fmt, len(odd), len(frames), med, '; '.join(odd[:12]) +
                 ('; ...' if len(odd) > 12 else '')))


def main():
    frames = []
    for line in sys.stdin:
        m = re.match(r'FRAME seq=(\d+) ts_ms=([\d.]+) sig=(\w+)', line)
        if m:
            frames.append((int(m.group(1)), float(m.group(2)), m.group(3)))
            continue
        m = re.match(r'RESULT capture fmt=(\S+)', line)
        if m:
            report(m.group(1), frames)
            frames = []


if __name__ == '__main__':
    main()
