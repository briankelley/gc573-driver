#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Summarise tests/exp-reset.sh output (open question 13): per reset
domain, the registers whose value changed across the reset (registers that
change by themselves between the two control snapshots are listed apart),
and the audio DMA's fate (K, A, S lines, printed as they are).
Usage: exp-reset.py LOG"""
import collections
import re
import sys

NAMES = {
    0x000: 'VERSION', 0x004: 'TLP_ALIGN', 0x008: 'DMA_RUN', 0x00c: 'RESET',
    0x010: 'INT_STATUS', 0x014: 'AUDIO_DONE', 0x01c: 'INT_ENABLE',
    0x040: 'GPIO', 0x100: 'I2C2 PRERlo', 0x104: 'I2C2 PRERhi',
    0x108: 'I2C2 CTR', 0x120: 'I2C0 PRERlo', 0x124: 'I2C0 PRERhi',
    0x128: 'I2C0 CTR', 0x200: 'AUD_CFG0', 0x204: 'AUD_PERIOD_A',
    0x208: 'AUD_BUF0_LO', 0x20c: 'AUD_BUF0_HI', 0x210: 'AUD_BUF1_LO',
    0x214: 'AUD_BUF1_HI', 0x218: 'AUD_CFG1', 0x21c: 'AUD_PERIOD_B',
    0x2b4: 'AUD_SLOT0', 0x2b8: 'AUD_SLOT1', 0x2bc: 'AUD_SLOT2',
    0x2c0: 'AUD_SLOT3', 0x1000: 'VIP_CTRL', 0x1004: 'IN_STATUS',
    0x1008: 'IN_WIDTH', 0x100c: 'IN_HEIGHT', 0x1010: 'IN_FRAME_PERIOD',
    0x1020: 'CLIP_LEFT', 0x1024: 'CLIP_WIDTH', 0x1028: 'CLIP_TOP',
    0x102c: 'CLIP_HEIGHT', 0x1040: 'COLOR_CTRL', 0x105c: 'CONTRAST',
    0x1060: 'BRIGHTNESS', 0x1064: 'HUE', 0x1068: 'SATURATION',
    0x107c: 'DDR_STATUS', 0x1080: 'RATE_CTRL', 0x1088: 'PIX_MODE',
    0x10a0: 'AUDIO_SAMPLE_PERIOD', 0x50000: 'SCALER_RESET',
}
for i in range(7):
    NAMES[0x10c0 + 4 * i] = f'CSC_RGB2YUV[{i}]'
    NAMES[0x10e0 + 4 * i] = f'CSC_YUV2RGB[{i}]'
for base, ch in ((0x300, 0), (0x500, 1), (0x600, 2)):
    NAMES[base] = f'CH{ch}_STATUS'
    NAMES[base + 4] = f'CH{ch}_CTRL'
    for n in range(4):
        NAMES[base + 8 + 12 * n] = f'CH{ch}_SLOT{n}_LO'
        NAMES[base + 12 + 12 * n] = f'CH{ch}_SLOT{n}_HI'
        NAMES[base + 16 + 12 * n] = f'CH{ch}_SLOT{n}_COUNT'
for base, sc, regs in ((0x40000, 'HSC', ('height', 'width_in', 'width_out', 'colour', 'pix_rate')),
                       (0x60000, 'VSC', ('height_in', 'width', 'height_out', 'line_rate'))):
    for i, r in enumerate(regs):
        NAMES[base + 0x10 + 8 * i] = f'{sc} {r}'


def name(off):
    return NAMES.get(off, '(unlisted)')


def main():
    snaps = collections.defaultdict(dict)
    other = []
    for line in open(sys.argv[1]):
        m = re.match(r'R (\S+) (0x[0-9a-f]+) (0x[0-9a-f]+)$', line.strip())
        if m:
            snaps[m.group(1)][int(m.group(2), 16)] = int(m.group(3), 16)
        elif re.match(r'(K|A|S|PARAMS|##) ', line):
            other.append(line.rstrip())
    noise = {o for o, v in snaps.get('ctl0', {}).items()
             if snaps.get('ctl1', {}).get(o) != v}
    print('changes by themselves (control pair): ' +
          (', '.join(f'{o:#x} {name(o)}' for o in sorted(noise)) or 'none'))
    for d in ('0x001', '0x100', '0x200', '0x301'):
        b, a = snaps.get(d + '-before'), snaps.get(d + '-after')
        if not b or not a:
            continue
        ch = [o for o in sorted(b) if b[o] != a.get(o)]
        print(f'\n## domain {d}: {len([o for o in ch if o not in noise])} registers changed')
        for o in ch:
            tag = '  (changes by itself)' if o in noise else ''
            print(f'  {o:#07x} {name(o):22s} {b[o]:#010x} -> {a[o]:#010x}{tag}')
    print()
    for line in other:
        print(line)


if __name__ == '__main__':
    main()
