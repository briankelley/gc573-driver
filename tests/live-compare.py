#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Compare a captured frame with the expected test pattern (PC loopback).

Usage: live-compare.py PATTERN.png FRAME FOURCC WIDTH HEIGHT [ENC] [RANGE]

PATTERN.png is tools/testsrc/pattern.py's image at the capture size (the
source shows it unscaled). FRAME is one raw frame from gc573-cap -o. ENC
(709 or 601) and RANGE (full or limited) describe the source RGB->YCbCr
conversion the driver programmed for YUV outputs (V4L2 ycbcr_enc; the
source RGB is full range).

RGB formats: per pixel and channel, captured - expected must be 0 or +1
(the loopback's known +1 on one pixel in four, spec/video-pipeline.md).
YUV formats: the expected values are the BT.709/601 limited-range Y'CbCr
of the source RGB, unrounded. Y is compared at every pixel; Cb and Cr at
every chroma sample whose source pixels (the 2x1 or 2x2 subsampling window
and one pixel around it) all have the same colour, so that the result does
not depend on the chroma filter. Prints the error statistics per channel
and "RESULT compare ... max_err=" lines; exits 1 if a limit is exceeded.
Limits: RGB 0..+1; YUV |err| <= YUV_TOL (below).
"""
import sys

import numpy as np
from PIL import Image

# Y'CbCr from 8-bit RGB through the 14-bit-coefficient CSC: rounding (0.5),
# plus the source's +1 on one pixel in four, which moves Y by up to 0.61
# (G weight 0.6142) and Cb/Cr by up to 0.44: |err| < 1.11. A truncating CSC
# would add up to 1 more. Limit: 2 code values.
YUV_TOL = 2

KRKB = {'709': (0.2126, 0.0722), '601': (0.299, 0.114)}


def ycbcr(rgb, enc):
    kr, kb = KRKB[enc]
    kg = 1 - kr - kb
    r, g, b = (rgb[..., i].astype(np.float64) / 255 for i in range(3))
    y = kr * r + kg * g + kb * b
    cb = (b - y) / (2 * (1 - kb))
    cr = (r - y) / (2 * (1 - kr))
    return 16 + 219 * y, 128 + 224 * cb, 128 + 224 * cr


def flat(rgb, sx, sy):
    """Mask of chroma sites whose window (+1 pixel around) is one colour."""
    h, w, _ = rgb.shape
    key = (rgb[..., 0].astype(np.int32) << 16) | (rgb[..., 1].astype(np.int32) << 8) | rgb[..., 2]
    ok = np.ones((h // sy, w // sx), dtype=bool)
    pad = np.pad(key, 1, mode='edge')
    ref = key[::sy, ::sx][:h // sy, :w // sx]
    for dy in range(-1, sy + 1):
        for dx in range(-1, sx + 1):
            sub = pad[1 + dy:1 + dy + h, 1 + dx:1 + dx + w][::sy, ::sx][:h // sy, :w // sx]
            ok &= sub == ref
    return ok


def stats(name, err, limit_lo, limit_hi, out):
    e = err.ravel()
    lo, hi = int(np.floor(e.min())), int(np.ceil(e.max()))
    bad = int(np.count_nonzero((e < limit_lo) | (e > limit_hi)))
    mx = float(np.abs(e).max())
    hist = ''
    if np.issubdtype(err.dtype, np.integer):
        vals, cnt = np.unique(e, return_counts=True)
        hist = ' hist=' + ','.join('%d:%d' % (v, c) for v, c in zip(vals, cnt))
    out.append('%s n=%d min=%d max=%d max_abs=%.2f out_of_limit=%d%s' %
               (name, e.size, lo, hi, mx, bad, hist))
    return bad, mx


def main():
    if len(sys.argv) < 6:
        sys.exit(__doc__)
    png, frame, fourcc = sys.argv[1:4]
    w, h = int(sys.argv[4]), int(sys.argv[5])
    enc = sys.argv[6] if len(sys.argv) > 6 else '709'
    exp = np.asarray(Image.open(png).convert('RGB'))
    if exp.shape[:2] != (h, w):
        sys.exit('pattern is %dx%d, frame %dx%d' % (exp.shape[1], exp.shape[0], w, h))
    raw = np.fromfile(frame, dtype=np.uint8)
    out, nbad, worst = [], 0, {}

    if fourcc in ('BGR3', 'XR24'):
        bpp = 3 if fourcc == 'BGR3' else 4
        img = raw[:w * h * bpp].reshape(h, w, bpp)
        for name, ci, ei in (('R', 2, 0), ('G', 1, 1), ('B', 0, 2)):
            err = img[..., ci].astype(np.int32) - exp[..., ei]
            b, mx = stats(name, err, 0, 1, out)
            nbad += b
            worst[name] = mx
        if bpp == 4:
            x = img[..., 3]
            out.append('X min=%d max=%d' % (x.min(), x.max()))
    else:
        ey, ecb, ecr = ycbcr(exp, enc)
        if fourcc in ('YUYV', 'UYVY'):
            p = raw[:w * h * 2].reshape(h, w // 2, 4)
            if fourcc == 'YUYV':
                y = np.stack((p[..., 0], p[..., 2]), axis=-1).reshape(h, w)
                cb, cr = p[..., 1], p[..., 3]
            else:
                y = np.stack((p[..., 1], p[..., 3]), axis=-1).reshape(h, w)
                cb, cr = p[..., 0], p[..., 2]
            sx, sy = 2, 1
        elif fourcc == 'NV12':
            y = raw[:w * h].reshape(h, w)
            c = raw[w * h:w * h * 3 // 2].reshape(h // 2, w // 2, 2)
            cb, cr = c[..., 0], c[..., 1]
            sx, sy = 2, 2
        elif fourcc == 'YV12':
            y = raw[:w * h].reshape(h, w)
            q = w * h // 4
            cr = raw[w * h:w * h + q].reshape(h // 2, w // 2)
            cb = raw[w * h + q:w * h + 2 * q].reshape(h // 2, w // 2)
            sx, sy = 2, 2
        else:
            sys.exit('format %s?' % fourcc)
        b, worst['Y'] = stats('Y', y - ey, -YUV_TOL, YUV_TOL, out)
        nbad += b
        m = flat(exp, sx, sy)
        ecb_s = ecb[::sy, ::sx][:h // sy, :w // sx]
        ecr_s = ecr[::sy, ::sx][:h // sy, :w // sx]
        b, worst['Cb'] = stats('Cb', (cb - ecb_s)[m], -YUV_TOL, YUV_TOL, out)
        nbad += b
        b, worst['Cr'] = stats('Cr', (cr - ecr_s)[m], -YUV_TOL, YUV_TOL, out)
        nbad += b
        out.append('chroma sites compared %d of %d (flat windows)' % (m.sum(), m.size))
    for line in out:
        print('INFO compare %s %s' % (fourcc, line))
    print('RESULT compare fmt=%s %dx%d enc=%s %s out_of_limit=%d' %
          (fourcc, w, h, enc, ' '.join('max_err_%s=%.2f' % kv for kv in worst.items()), nbad))
    sys.exit(1 if nbad else 0)


if __name__ == '__main__':
    main()
