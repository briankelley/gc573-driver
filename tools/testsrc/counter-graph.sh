#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# The ffmpeg filter graph (video only) of the live test picture: pattern.py's
# exact-value pattern with a frame counter and a flash box in its bottom band,
# the 1-pixel checkerboard, which no image check uses. Used by show.sh
# --counter and avsync.sh --pattern; tests/obs-events.py reads the picture
# with the same geometry:
# - the counter: the frame index n in binary, 16 squares of B = H/27 pixels,
#   bit k at x = W/16 + k * 3B/2, y = 4H/5 + (H/5 - B)/2, white for 1, on a
#   black strip from B/4 left of bit 0 to B/4 right of bit 15 and B/4 above
#   and below;
# - the flash: a box from 11W/16 to 15W/16 across the same strip height,
#   black, white in every frame whose index is a multiple of N.
# Usage: counter-graph.sh PNG W H FPS N   (FPS as ffmpeg takes it: 60, 60000/1001)
set -eu
png=$1 w=$2 h=$3 fps=$4 n=$5
B=$((h / 27)) p=$((h / 27 * 3 / 2)) x0=$((w / 16)) m=$((h / 27 / 4))
y0=$((h * 4 / 5 + (h - h * 4 / 5 - B) / 2))
fx=$((w * 11 / 16)) fw=$((w * 15 / 16 - w * 11 / 16))
g="movie=$png,loop=loop=-1:size=1:start=0,setpts=N/($fps)/TB,format=rgb24"
g+=",drawbox=x=$((x0 - m)):y=$((y0 - m)):w=$((15 * p + B + 2 * m)):h=$((B + 2 * m)):color=black:t=fill"
for k in $(seq 0 15); do
	g+=",drawbox=x=$((x0 + k * p)):y=$y0:w=$B:h=$B:color=white:t=fill:enable='mod(floor(n/$((1 << k)))\\,2)'"
done
g+=",drawbox=x=$fx:y=$((y0 - m)):w=$fw:h=$((B + 2 * m)):color=black:t=fill"
g+=",drawbox=x=$fx:y=$((y0 - m)):w=$fw:h=$((B + 2 * m)):color=white:t=fill:enable='eq(mod(n\\,$n)\\,0)'"
printf '%s\n' "$g"
