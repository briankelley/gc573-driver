#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""exp-delivery.sh: completion rate, repeat pattern (runs of identical
frames) and the registers that change between completions, with how a
change agrees with a new image (spec/open-questions.md #33)."""
import re
import sys
from collections import Counter

frames, regs = [], {}
for line in open(sys.argv[1]):
    m = re.match(r'FRAME seq=(\d+) ts_ms=([\d.]+) sig=(\w+)', line)
    if m:
        frames.append((int(m[1]), float(m[2]), m[3]))
        continue
    m = re.match(r'REGS seq=(\d+) (.*)', line)
    if m:
        regs[int(m[1])] = [int(v, 16) for v in m[2].split()]
# REGS: 0x300-0x3fc then 0x1000-0x10fc (128 words); early runs logged
# 0x300 and 0x1000-0x10fc only (65)
width = len(next(iter(regs.values()))) if regs else 128
CH0 = 64 if width == 128 else 1
names = ['%04x' % (0x300 + 4 * i) for i in range(CH0)] + \
    ['%04x' % (0x1000 + 4 * i) for i in range(64)]
VIP = CH0	# index of 0x1000
if not frames:
    sys.exit('no frames')
runs, cur = [], 1
for i in range(1, len(frames)):
    if frames[i][2] == frames[i - 1][2]:
        cur += 1
    else:
        runs.append(cur)
        cur = 1
runs.append(cur)
dur = (frames[-1][1] - frames[0][1]) / 1000
print('frames %d over %.3f s: %.3f completions/s, %d distinct images (%.3f/s)'
      % (len(frames), dur, (len(frames) - 1) / dur,
         len(set(f[2] for f in frames)), len(runs) / dur))
print('run lengths:', dict(sorted(Counter(runs).items())))
print('first 40 runs:', runs[:40])
rep = [None] + [frames[i][2] == frames[i - 1][2] for i in range(1, len(frames))]
seqs = [f[0] for f in frames]
if not regs:
    sys.exit(0)
print('registers that change between completions, and how the change agrees'
      ' with "new image" (sig differs):')
for k, name in enumerate(names):
    vals = [regs[s][k] for s in seqs if s in regs]
    if len(set(vals)) == 1:
        continue
    agree = tot = 0
    ch_new = ch_rep = same_new = same_rep = 0
    for i in range(1, len(seqs)):
        a, b = regs.get(seqs[i - 1]), regs.get(seqs[i])
        if a is None or b is None:
            continue
        changed = a[k] != b[k]
        new = not rep[i]
        tot += 1
        agree += changed == new
        ch_new += changed and new
        ch_rep += changed and not new
        same_new += (not changed) and new
        same_rep += (not changed) and not new
    vs = sorted(Counter(vals).items(), key=lambda x: -x[1])[:4]
    print('  %s: %d values, agreement %.2f (changed: new %d rep %d; same: new %d rep %d); top %s'
          % (name, len(set(vals)), agree / tot if tot else 0, ch_new, ch_rep,
             same_new, same_rep, ', '.join('%08x x%d' % v for v in vs)))
# CH_STATUS bits above the slot index
print('CH_STATUS[31:3] by image kind:')
for kind in (False, True):
    c = Counter(regs[seqs[i]][0] >> 3 for i in range(1, len(seqs))
                if seqs[i] in regs and rep[i] == kind)
    print('  %s: %s' % ('repeat' if kind else 'new   ',
                        ', '.join('%x x%d' % v for v in sorted(c.items())[:12])))
first = regs[seqs[0]] if seqs[0] in regs else next(iter(regs.values()))
print('first snapshot: RATE_CTRL(1080) %08x COLOR_CTRL(1040) %08x VIP_CTRL(1000) %08x PIX_MODE(1088) %08x'
      % (first[VIP + 0x80 // 4], first[VIP + 0x40 // 4], first[VIP], first[VIP + 0x88 // 4]))
