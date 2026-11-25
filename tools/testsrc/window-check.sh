#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Check a test source's player window (show.sh, avsync.sh; host only): within
# 5 s the window named TITLE must be override-redirect (the window manager
# never manages or moves it, so it cannot end up on the main screen) and sit
# at +X+0 with size WxH. Prints what it found; exit status 0 if so.
# Usage: window-check.sh TITLE W H X
t=$1 w=$2 h=$3 x=$4
command -v xwininfo > /dev/null || { echo "xwininfo is not installed (x11-utils): cannot check the window"; exit 1; }
found=
for _ in $(seq 50); do
	if i=$(xwininfo -name "$t" 2>/dev/null); then
		ax=$(sed -n 's/^ *Absolute upper-left X: *//p' <<< "$i")
		ay=$(sed -n 's/^ *Absolute upper-left Y: *//p' <<< "$i")
		ww=$(sed -n 's/^ *Width: *//p' <<< "$i")
		wh=$(sed -n 's/^ *Height: *//p' <<< "$i")
		or=$(sed -n 's/^ *Override Redirect State: *//p' <<< "$i")
		found="+$ax+$ay ${ww}x$wh, override redirect $or"
		if [ "$or" = yes ] && [ "$ax" = "$x" ] && [ "$ay" = 0 ] && [ "$ww" = "$w" ] && [ "$wh" = "$h" ]; then
			echo "window $t: $found"
			exit 0
		fi
	fi
	sleep 0.1
done
echo "window $t: ${found:-not found} (want +$x+0 ${w}x$h, override redirect yes)"
exit 1
