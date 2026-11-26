#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# The live test picture as a video file the Roku can play (Roku media
# specification: H.264 High up to 1080p and 10 Mbps, MP4, AAC 48 kHz
# stereo). The counter and the flash box of tools/testsrc/counter-graph.sh
# (same geometry, so live-av.py --exact and obs-events.py read it), on a
# grey picture with six solid patches (black, white, 50 % grey, red, green,
# blue: a coarse colour and range check that survives the encoding). The
# burst of avsync.sh with each flash: one frame of 1 kHz left and 2 kHz
# right. pattern.py's exact values do not survive H.264; nothing checks
# them on this source. tools/roku/check-video.py checks a file.
# Usage: tools/roku/pattern-video.sh OUT.mp4 [SECS [W H FPS N]]
#   default 600 s, 1920 1080 60 60 (a flash and a burst every second)
set -euo pipefail
out=$1 secs=${2:-600} w=${3:-1920} h=${4:-1080} fps=${5:-60} n=${6:-60}
here=$(cd "$(dirname "$0")/.." && pwd)/testsrc
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# the base picture: patches 1/8 of the width, in the top half
pw=$((w / 8)) ph=$((h / 4)) py=$((h / 8))
g="color=c=0x505050:s=${w}x$h,format=rgb24"
i=0
for c in black white 0x808080 red lime blue; do
	g+=",drawbox=x=$((w / 16 + i * (pw + w / 32))):y=$py:w=$pw:h=$ph:color=$c:t=fill"
	i=$((i + 1))
done
ffmpeg -hide_banner -loglevel error -f lavfi -i "$g" -frames:v 1 -y "$tmp/base.png"
# counter-graph.sh's drawbox chain (the part after its movie= source, which
# says 25 Hz: ffmpeg's constant-rate output then repeated the first frame,
# shifting every counter by one) on the base picture looped at FPS (a whole
# number, as the Roku's 24-60p are): frame n is the n-th of the loop
case $fps in *[!0-9]*) echo "FPS: a whole number" >&2; exit 2 ;; esac
g=$("$here/counter-graph.sh" "$tmp/base.png" "$w" "$h" "$fps" "$n")
chain=${g#*,format=rgb24}
[ "$chain" != "$g" ] || { echo "counter-graph.sh: no format=rgb24 in its graph" >&2; exit 2; }
period="($n/($fps))" frame="(1/($fps))"
gate="lt(mod(t\\,$period)\\,$frame)"
# BT.709 limited range, as a player expects; a keyframe every 2 s; the
# picture is static but for the counter, so the rate stays far below the
# Roku's 10 Mbps
ffmpeg -hide_banner -loglevel error -loop 1 -framerate "$fps" -i "$tmp/base.png" \
	-f lavfi -i "aevalsrc=exprs='0.5*sin(2*PI*1000*t)*$gate|0.5*sin(2*PI*2000*t)*$gate':channel_layout=stereo:sample_rate=48000" \
	-filter_complex "[0:v]format=rgb24$chain,scale=out_color_matrix=bt709:out_range=tv[v]" \
	-map '[v]' -map 1:a -t "$secs" \
	-c:v libx264 -preset medium -profile:v high -level:v 4.2 -crf 16 \
	-maxrate 8M -bufsize 16M -g $((2 * fps)) -pix_fmt yuv420p \
	-colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv \
	-c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart -y "$out"
echo "$out: ${w}x$h at $fps, $secs s, flash and burst every $n frames ($(du -h "$out" | cut -f1))"
