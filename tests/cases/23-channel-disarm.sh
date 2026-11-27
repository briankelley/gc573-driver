#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Every stop and start disarms all three video channels (security review
# of a0adb1d, F4): after a YV12 stream, which arms ch1 and ch2, and its
# STREAMOFF, the CH_CTRL values the driver last wrote to ch1 and ch2
# (debugfs "ch_ctrl written"; the registers cannot be read back) must be
# 0, and stay 0 through a YUYV stream that does not use them. Each stream
# must deliver its frames pattern-checked (-p): the disarm and the dummy
# lists change nothing a stream sees. No input (free-running 1080p).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

work=$(mktemp -d)
cap=$(gc573_cap_build "$work") || fail "cannot build gc573-cap"
gc573_load || fail "insmod failed"
trap 'gc573_loaded && gc573_unload; rm -rf "$work"' EXIT
vdev=$(gc573_video_dev) || fail "no video device"
gc573_input_off "$vdev"
bad=0

written() { grep -o 'ch_ctrl written: ch1 [^ ]* ch2 [^ ]*' "$(gc573_debugfs)"; }

check() {
	local w
	w=$(written)
	if [ "$w" = "ch_ctrl written: ch1 0 ch2 0" ] ||
	   [ "$w" = "ch_ctrl written: ch1 0x0 ch2 0x0" ]; then
		echo "ok:   $1: $w"
	else
		echo "BAD:  $1: $w (expected 0 and 0)"
		bad=1
	fi
}

for f in YV12 NV12; do
	"$cap" -d "$vdev" -f "$f" -n 30 -p > "$work/$f.log" 2>&1 ||
		{ cat "$work/$f.log"; fail "$f capture failed"; }
	check "after a $f stream"
done
"$cap" -d "$vdev" -f YUYV -n 300 -p > "$work/yuyv.log" 2>&1 &
pid=$!
sleep 2
check "during a YUYV stream"
wait "$pid" || { cat "$work/yuyv.log"; fail "YUYV capture failed"; }
check "after it"
[ "$bad" = 0 ] || fail "a channel stayed armed"
echo "every channel disarmed at each stop and start"
