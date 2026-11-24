#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Exact-value RGB test pattern for capture verification (no anti-aliasing, no gradients).
Rows: 8 colour bars 100%; 16-step grey ramp; limited-range markers; 1-px checkerboard; corner markers."""
import sys
from PIL import Image, ImageDraw
W, H = (int(v) for v in (sys.argv[2:4] if len(sys.argv) > 3 else (1920, 1080)))
out = sys.argv[1] if len(sys.argv) > 1 else 'pattern.png'
im = Image.new('RGB', (W, H), (0, 0, 0)); d = ImageDraw.Draw(im)
bars = [(255,255,255),(255,255,0),(0,255,255),(0,255,0),(255,0,255),(255,0,0),(0,0,255),(0,0,0)]
h1, h2, h3 = H*4//10, H*6//10, H*8//10
for i, c in enumerate(bars):
    d.rectangle([i*W//8, 0, (i+1)*W//8-1, h1-1], fill=c)
for i in range(16):
    v = i*17
    d.rectangle([i*W//16, h1, (i+1)*W//16-1, h2-1], fill=(v, v, v))
marks = [(16,16,16),(235,235,235),(16,128,128),(128,16,240),(240,128,16),(1,2,3),(254,253,252),(100,150,200)]
for i, c in enumerate(marks):
    d.rectangle([i*W//8, h2, (i+1)*W//8-1, h3-1], fill=c)
px = im.load()
for y in range(h3, H):
    for x in range(W):
        if (x + y) & 1: px[x, y] = (255, 255, 255)
for (x, y) in [(0, 0), (W-8, 0), (0, H-8), (W-8, H-8)]:
    d.rectangle([x, y, x+7, y+7], fill=(255, 0, 0))
    d.rectangle([x+2, y+2, x+5, y+5], fill=(0, 255, 0))
im.save(out)
print(out, W, H)
