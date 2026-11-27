#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Classify the frames a second user (B) got against the first user's (A).

Usage: remnant-frames.py A_FRAME A_W A_H PATTERN.png|- W H FRAME...

A_FRAME: A's last frame (YUYV, A_W x A_H; gc573-cap -o), what the card's
frame store held when A stopped (A's frames had one signature).
PATTERN.png: tools/testsrc/pattern.py at W x H, what B's source shows;
"-": no input, B should get the free-run black (luma 16 everywhere,
spec/video-dma.md). FRAME: B's frames kept by gc573-cap -K (YUYV, W x H).

Luma, with live-compare.py's tolerance (YUV_TOL). Per frame one line,
"FRAME file=F class=C ...", C one of:
  expected   every pixel within the tolerance of PATTERN (or the black);
  uniform    one 32-bit word everywhere (with no input: the free-run black);
  a-frame    the bytes of A's frame (same size only);
  a-content  rows that hold A's picture (below);
  other      none of these.
For a-content and other: the rows off the expected picture (ranges) and
the columns they span; how many of them are uniform, and how many are a
row of the expected picture from elsewhere (shifted or repeated). Then,
per layout of A's frame in the card's store, the rows of B that hold A's
picture: crop (B's row r, column c = A's row r, column c), linear (B's
pixel i = A's pixel i in raster order), exact (B's row = the first W*2
bytes of any row of A that is not all black). Under crop and linear a
row holds A's picture when, of its pixels off the expected picture, not
black, and where A's luma is more than twice the tolerance from the
expected (at least 32 of them), half or more are within the tolerance of
A's; max= is the largest such share in any row. Black is left out (A's
black bars say nothing), and so are rows from elsewhere in the expected
picture, which A's picture shares (its checkerboard rows are the 720p
ones). A uniform row is judged like any other: a checkerboard row is one
32-bit word repeated.
Then "RESULT a-content PASS|FAIL (...)": FAIL if a frame is a-frame or
a-content. Exit 1 on FAIL.
"""
import importlib.util
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location('live_compare', os.path.join(HERE, 'live-compare.py'))
lc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lc)
TOL = lc.YUV_TOL
BLACK = 16      # the free-run black's luma (spec/video-dma.md)
MIN_PIX = 32    # pixels a row needs to be judged under crop and linear


def ranges(rows):
    """'0-23,700-719' for sorted row numbers"""
    out, start, prev = [], None, None
    for r in list(rows) + [None]:
        if start is not None and (r is None or r != prev + 1):
            out.append(f'{start}-{prev}' if prev > start else f'{start}')
            start = None
        if r is not None:
            if start is None:
                start = r
            prev = r
    return ','.join(out) or 'none'


def luma(raw, w, h):
    p = raw[:w * h * 2].reshape(h, w // 2, 4)
    return np.stack((p[..., 0], p[..., 2]), axis=-1).reshape(h, w).astype(np.int16)


def a_rows(y, ey, ya, offp, judged):
    """the judged rows of y that hold ya's picture, and the largest share"""
    cand = offp & (np.abs(y - BLACK) > TOL) & (np.abs(ya - ey) > 2 * TOL)
    cand &= judged[:, None]
    hit = cand & (np.abs(y - ya) <= TOL)
    nc, nh = cand.sum(axis=1), hit.sum(axis=1)
    share = np.where(nc >= MIN_PIX, nh / np.maximum(nc, 1), 0.0)
    return np.flatnonzero(share >= 0.5), float(share.max())


def main():
    if len(sys.argv) < 8:
        sys.exit(__doc__)
    a_file, png = sys.argv[1], sys.argv[4]
    aw, ah, w, h = (int(v) for v in (sys.argv[2], sys.argv[3], sys.argv[5], sys.argv[6]))
    frames = sys.argv[7:]
    a = np.fromfile(a_file, dtype=np.uint8)
    if a.size < aw * ah * 2:
        sys.exit(f'{a_file}: {a.size} bytes, not {aw}x{ah} YUYV')
    a = a[:aw * ah * 2]
    ya = luma(a, aw, ah)
    layouts = {}
    if h <= ah and w <= aw:
        layouts['crop'] = ya[:h, :w]
    if w * h <= aw * ah:
        layouts['linear'] = ya.reshape(-1)[:w * h].reshape(h, w)
    rb = w * 2
    prefix = {}
    if rb <= aw * 2:
        arows = a.reshape(ah, aw * 2)
        black = np.all(np.abs(ya - BLACK) <= TOL, axis=1)
        for r in range(ah):
            if not black[r]:
                prefix.setdefault(arows[r, :rb].tobytes(), r)
    if png == '-':
        ey = np.full((h, w), float(BLACK))
    else:
        exp = np.asarray(Image.open(png).convert('RGB'))
        if exp.shape[:2] != (h, w):
            sys.exit(f'pattern is {exp.shape[1]}x{exp.shape[0]}, frames {w}x{h}')
        ey = lc.ycbcr(exp, '709')[0]
    # the expected picture's distinct rows, for rows from elsewhere in it
    urows = np.unique(np.round(ey).astype(np.int16), axis=0)
    bad = []
    for f in frames:
        raw = np.fromfile(f, dtype=np.uint8)
        if raw.size < w * h * 2:
            print(f'FRAME file={f} class=short bytes={raw.size}')
            bad.append(f)
            continue
        raw = raw[:w * h * 2]
        words = raw.view(np.uint32)
        if np.all(words == words[0]):
            print(f'FRAME file={f} class=uniform word={words[0]:08x}')
            continue
        if (w, h) == (aw, ah) and np.array_equal(raw, a):
            print(f"FRAME file={f} class=a-frame (the bytes of A's frame)")
            bad.append(f)
            continue
        y = luma(raw, w, h)
        offp = np.abs(y - ey) > TOL
        off = np.flatnonzero(offp.any(axis=1))
        if off.size == 0:
            print(f'FRAME file={f} class=expected')
            continue
        brows = raw.reshape(h, rb)
        rw = brows.view(np.uint32)
        uni = np.all(rw == rw[:, :1], axis=1)
        dist = np.full(h, np.iinfo(np.int16).max, dtype=np.int32)
        for u in urows:
            dist[off] = np.minimum(dist[off], np.abs(y[off] - u).max(axis=1))
        elsewhere = dist <= TOL + 1
        judged = np.zeros(h, dtype=bool)
        judged[off] = True
        judged &= ~elsewhere
        cols = np.flatnonzero(offp.any(axis=0))
        parts, hit = [], False
        for name, yl in layouts.items():
            rows, mx = a_rows(y, ey, yl, offp, judged)
            parts.append(f'{name}={rows.size} ({ranges(rows)}) max={mx:.2f}')
            hit |= rows.size > 0
        ex = [r for r in np.flatnonzero(judged) if brows[r].tobytes() in prefix]
        parts.append(f'exact={len(ex)}' + (
            f" ({ranges(ex)} = A's rows {ranges(sorted({prefix[brows[r].tobytes()] for r in ex}))})"
            if ex else ''))
        hit |= bool(ex)
        print(f'FRAME file={f} class={"a-content" if hit else "other"} rows_off={off.size} '
              f'({ranges(off)}) columns {cols[0]}-{cols[-1]}, uniform {int(uni[off].sum())}, '
              f'from elsewhere {int(elsewhere[off].sum())}; '
              f"A's picture: " + ' '.join(parts))
        if hit:
            bad.append(f)
    print(f'RESULT a-content {"PASS" if not bad else "FAIL"} ({len(frames)} frames, '
          f"{len(bad)} with A's picture{': ' + ' '.join(bad) if bad else ''})")
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
