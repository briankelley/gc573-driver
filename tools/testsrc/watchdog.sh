#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Test source watchdog for show.sh and avsync.sh (host only). While the player
# PID runs, every 0.2 s: OUTPUT must still be connected and showing the
# player's geometry, WxH+X+0. Otherwise (the output switched off, which
# xrandr shows as "OUTPUT connected (" with no geometry; unplugged; another
# mode; moved) it runs CMD (default: kill PID) and exits.
# The player window is override-redirect, so the window manager never moves
# it to another screen when its output goes away; this closes it as well.
# Usage: watchdog.sh PID OUTPUT W H X [CMD...]
pid=$1 out=$2 w=$3 h=$4 x=$5
shift 5
while kill -0 "$pid" 2>/dev/null; do
	# --current: no re-probe; hotplug events keep the RandR state current
	if ! xrandr --current 2>/dev/null | grep -q "^$out connected \(primary \)\?${w}x$h+$x+0 "; then
		if [ $# -gt 0 ]; then "$@"; else kill "$pid"; fi
		exit 0
	fi
	sleep 0.2
done
