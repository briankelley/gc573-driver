#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# What the HDMI source sees while gc573 is unloaded and loaded again (host
# side, PC loopback; the driver runs in the VM). gc573_hdmi_hpd_off() drives
# the source HPD and splitter port 1's HPD low at remove, so the source
# should see the card leave: its output turned off or its ELD invalidated.
# Polled: the NVIDIA HDMI audio function's ELD for the capture card's port
# (/proc/asound/cardN/eld#M, monitor_present and eld_valid) every 10 ms, and
# OUTPUT's xrandr state every 100 ms. Each change is logged with UTC ms, as
# are the rmmod at +3 s and the insmod at +11 s; the run ends at +21 s.
# No test player runs; tools/testsrc/guard.py watches. The module must be
# loaded and OUTPUT on with the card's ELD (GC573 in the ELD's monitor name).
# Usage: tests/hpd-unload.sh [LOG] (env VM, VMDIR, OUTPUT, ELD)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VM=${VM:-gc573-dev} VMDIR=${VMDIR:-gc573-driver} OUT=${OUTPUT:-DVI-D-0}
LOG=${1:-/tmp/gc573-hpd-unload.log}
ELD=${ELD:-$(grep -l 'GC573' /proc/asound/card*/eld#* 2>/dev/null | head -1)}
export GC573_EVENT_LOG=$LOG
ts() { date -u +%FT%T.%3NZ; }
ev() { echo "$(ts) hpd-unload $*" >> "$LOG"; }
[ -n "$ELD" ] || { echo "no ELD with GC573 in it: is $OUT on, with the card's EDID?"; exit 2; }
python3 "$ROOT/tools/testsrc/guard.py" --pid $$ --log "$LOG" --output "$OUT" &
"$ROOT/tools/testsrc/avsync.sh" --off; "$ROOT/tools/testsrc/show.sh" --off
poll() {
	local e0="" x0="" e x n=0
	while :; do
		e=$(awk '/^monitor_present/ { m = $2 } /^eld_valid/ { v = $2 }
			END { print "monitor_present " m " eld_valid " v }' "$ELD")
		[ "$e" = "$e0" ] || { ev "ELD $e"; e0=$e; }
		if [ $((n % 10)) = 0 ]; then
			x=$(xrandr --current | awk -v o="$OUT" '$1 == o { print $2, $3 }')
			[ "$x" = "$x0" ] || { ev "xrandr $OUT $x"; x0=$x; }
		fi
		n=$((n + 1))
		sleep 0.01
	done
}
poll &
pp=$!
trap 'kill $pp 2>/dev/null' EXIT
sleep 3
ev "driver unload (rmmod gc573 in $VM)"
ssh -n "$VM" 'sudo rmmod gc573' && ev "rmmod returned"
sleep 8
ev "driver load (insmod ~/$VMDIR/gc573.ko in $VM)"
ssh -n "$VM" "cd $VMDIR && sudo insmod ./gc573.ko" && ev "insmod returned"
sleep 10
grep ' hpd-unload ' "$LOG"
