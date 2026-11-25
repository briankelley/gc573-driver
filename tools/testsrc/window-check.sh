#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Check a test source's player window (show.sh, avsync.sh; host only). Within
# 5 s, the window named TITLE must be override-redirect (the window manager
# never manages or moves it, so it cannot end up on the main screen), mapped,
# and sit at +X+0 with size WxH. It prints what it found and exits 0 if so.
# "Mapped" matters: place.so gives the window its geometry before the map, so
# without it the check could pass in the moment before the map. The callers
# then read place.so's "mapped at" line, which is written before any other
# client can see the map. With PID, it gives up as soon as that player has
# exited (place.so refused the map).
# Usage: window-check.sh TITLE W H X [PID]
t=$1 w=$2 h=$3 x=$4 pid=${5:-}
command -v xwininfo > /dev/null || { echo "xwininfo is not installed (x11-utils): cannot check the window"; exit 1; }
found=
for _ in $(seq 50); do
	if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
		echo "window $t: the player (pid $pid) exited (want +$x+0 ${w}x$h, override redirect yes, IsViewable)"
		exit 1
	fi
	if i=$(xwininfo -name "$t" 2>/dev/null); then
		ax=$(sed -n 's/^ *Absolute upper-left X: *//p' <<< "$i")
		ay=$(sed -n 's/^ *Absolute upper-left Y: *//p' <<< "$i")
		ww=$(sed -n 's/^ *Width: *//p' <<< "$i")
		wh=$(sed -n 's/^ *Height: *//p' <<< "$i")
		or=$(sed -n 's/^ *Override Redirect State: *//p' <<< "$i")
		ms=$(sed -n 's/^ *Map State: *//p' <<< "$i")
		found="+$ax+$ay ${ww}x$wh, override redirect $or, $ms"
		if [ "$or" = yes ] && [ "$ms" = IsViewable ] && [ "$ax" = "$x" ] && [ "$ay" = 0 ] &&
			[ "$ww" = "$w" ] && [ "$wh" = "$h" ]; then
			echo "window $t: $found"
			exit 0
		fi
	fi
	sleep 0.1
done
echo "window $t: ${found:-not found} (want +$x+0 ${w}x$h, override redirect yes, IsViewable)"
exit 1
