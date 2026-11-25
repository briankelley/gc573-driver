#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Shows that a test player's window is never mapped anywhere but OUTPUT.
# Host only: PC loopback, with gc573 loaded in the VM.
#
# N player starts (default 528), in turn:
# - 4 each of show.sh, show.sh --counter, avsync.sh --pattern and
#   avsync.sh (the flash clip), the avsync.sh ones silent (--amplitude 0);
# - each at the next mode of 1920x1080@60, 1920x1080@59.94, 1280x720@59.94,
#   1280x720@60, so every start changes the rate, the resolution, or both.
# Mixed in:
# - before every 10th start, the output is off for 1 s, then on again at the
#   start's mode;
# - before every 25th, an EDID set in the VM (the other image, then the
#   default; each a hot-plug), and the start as soon as the output is back.
#   That was the situation at the guard's false breach (2026-11-25
#   17:49:21.807Z).
# After either, the start waits for the capture card's ELD (up to 5 s):
# avsync.sh needs it before it sets the mode.
# A failed start is logged and tried once more after 2 s.
#
# guard.py watches the run. Its X11 event watcher (xwatch.py) logs every test
# window's create, configure and map with the geometry, and stops the run at
# a map outside OUTPUT. The players run with place.so: a window is created at
# its final geometry and mapped only after a check.
#
# Results:
# - starts: all made, in at most two tries;
# - maps: every map inside OUTPUT;
# - geometry: no test window ever had a geometry outside OUTPUT, mapped or
#   not;
# - guard: no breach.
# Log: tests/logs/<UTC>-window-proof.log, the event log (UTC, ms): players,
# modes, EDID, output off/on, and every X11 event of a test window.
# Usage: tests/window-proof.sh [N]   (env VM, OUTPUT)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TS=$ROOT/tools/testsrc
N=${1:-528} VM=${VM:-gc573-dev} OUT=${OUTPUT:-DVI-D-0}
VDEV=/dev/v4l/by-path/pci-0000:07:00.0-video-index0
log=$ROOT/tests/logs/$(date -u +%Y%m%dT%H%M%SZ)-window-proof.log
export GC573_EVENT_LOG=$log DISPLAY=${DISPLAY:-:0}
ev() { echo "$(date -u +%FT%T.%3NZ) proof $*" >> "$log"; }
off() { "$TS/avsync.sh" --off; "$TS/show.sh" --off; }
modes=("1920x1080 60" "1920x1080 59.94" "1280x720 59.94" "1280x720 60")
kinds=("show" "show --counter" "avsync --pattern" "avsync")
EDID=/tmp/gc573-window-proof

has_mode() { xrandr --current | grep -q "^$OUT connected \(primary \)\?[0-9]*x[0-9]*+"; }

edid_set() {
	ev "edid set: $1 image"
	ssh -n "$VM" "v4l2-ctl -d $VDEV --set-edid=file=$EDID/$1.bin,format=raw" > /dev/null
}

# after an EDID set: the hot-plug takes the mode away; wait until the desktop
# has the output back with a mode (or 5 s), then start at once
wait_hotplug() {
	local i
	for i in $(seq 40); do has_mode || break; sleep 0.1; done
	ev "output after the EDID set: $(has_mode && echo 'mode kept (no hot-plug seen)' || echo 'mode gone')"
	for i in $(seq 50); do has_mode && break; sleep 0.1; done
	ev "output: $(xrandr --current | grep "^$OUT ")"
}

# the capture card's ELD (its EDID's monitor name, GC573) valid on the NVIDIA HDMI audio
wait_eld() {
	local i f
	for i in $(seq 50); do
		for f in $(grep -ls GC573 /proc/asound/card*/eld#*); do
			grep -q '^eld_valid[[:space:]]*1' "$f" && { ev "ELD valid ($f)"; return 0; }
		done
		sleep 0.1
	done
	ev "no valid ELD after 5 s"
	return 1
}

start() { # KIND MODE RATE
	local a o try
	case $1 in
	show) a=("$TS/show.sh" "$OUT" "$2" "$3") ;;
	"show --counter") a=("$TS/show.sh" --counter "$OUT" "$2" "$3") ;;
	"avsync --pattern") a=("$TS/avsync.sh" --pattern --amplitude 0 "$OUT" "$2" "$3") ;;
	avsync) a=("$TS/avsync.sh" --amplitude 0 "$OUT" "$2" "$3") ;;
	esac
	for try in 1 2; do
		if o=$("${a[@]}" 2>&1); then
			echo ok
			return 0
		fi
		ev "start failed (try $try, $1 $2@$3): $(tr '\n' ' ' <<< "$o")"
		sleep 2
	done
	echo failed
	return 1
}

main() {
	local i k m r e=other ok=0 bad=0
	until grep -q ' guard start:' "$log" 2>/dev/null; do sleep 0.1; done
	sleep 0.5
	ssh -n "$VM" "mkdir -p $EDID && v4l2-ctl -d $VDEV --get-edid=file=$EDID/default.bin,format=raw >/dev/null && python3 -c \"import sys; d=bytearray(open(sys.argv[1],'rb').read()); d[0x0c]^=0x5a; d[0x7f]=-sum(d[0:0x7f]) & 0xff; open(sys.argv[2],'wb').write(d)\" $EDID/default.bin $EDID/other.bin" ||
		{ ev "cannot prepare the EDID images in $VM"; exit 1; }
	ev "start: $N player starts on $OUT"
	for i in $(seq 0 $((N - 1))); do
		k=${kinds[$(((i / 4) % 4))]}
		read -r m r <<< "${modes[$((i % 4))]}"
		if [ $((i % 25)) = 24 ]; then
			off
			edid_set "$e"
			[ "$e" = other ] && e=default || e=other
			wait_hotplug
			wait_eld
		elif [ $((i % 10)) = 9 ]; then
			off
			ev "output off $OUT"
			xrandr --output "$OUT" --off
			sleep 1
			ev "output on $OUT $m@$r"
			xrandr --output "$OUT" --mode "$m" --rate "$r" --right-of "$(xrandr --current | awk '/ connected primary/ {print $1; exit}')"
			wait_eld
		fi
		if [ "$(start "$k" "$m" "$r")" = ok ]; then ok=$((ok + 1)); else bad=$((bad + 1)); fi
		sleep 0.3
	done
	off
	[ "$e" = default ] && edid_set default && wait_hotplug
	ev "end: starts $ok made, $bad failed twice"
}

main &
mp=$!
python3 "$TS/guard.py" --pid $mp --log "$log" --output "$OUT"
gst=$?
wait $mp 2>/dev/null
off
s=$(grep -o ' guard end: .*' "$log" | tail -1)
made=$(grep -o 'proof end: starts [0-9]* made, [0-9]* failed' "$log" | tail -1)
creates=$(grep -c ' guard x11 create ' "$log")
outside_c=$(grep -c ' guard x11 create .*(unmapped; ' "$log")
maps=$(grep -c ' guard x11 map ' "$log")
maps_in=$(grep -c ' guard x11 map .*: inside ' "$log")
unm=$(sed -n 's/.*unmapped geometries outside \([0-9]*\),.*/\1/p' <<< "$s")
starts=$(grep -c -E ' (show|avsync) player start ' "$log")
res() { printf 'RESULT %-24s %s (%s)\n' "$1" "$([ "$2" = 1 ] && echo PASS || echo FAIL)" "$3"; }
res window-proof-starts "$([ -n "$made" ] && grep -q ' 0 failed' <<< "$made" && echo 1)" \
	"${made#proof end: }; $starts player starts logged; $(grep -c ' proof start failed ' "$log") failed tries"
res window-proof-maps "$([ "$maps" -gt 0 ] && [ "$maps" = "$maps_in" ] && echo 1)" \
	"$maps maps of test windows, $maps_in inside $OUT, $((maps - maps_in)) outside"
res window-proof-geometry "$([ "$outside_c" = 0 ] && [ "${unm:-x}" = 0 ] && echo 1)" \
	"$creates test windows created, $outside_c created outside $OUT, ${unm:-?} unmapped geometries outside it"
res window-proof-guard "$([ "$gst" = 0 ] && ! grep -q BREACH "$log" && echo 1)" \
	"guard exit $gst; ${s# guard }"
echo "log: ${log#"$ROOT"/}"
