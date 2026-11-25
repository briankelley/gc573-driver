#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M2: stream start/stop and buffer-starvation robustness, no input.
# - GC573_CYCLES (default 100) cycles of S_FMT (the six formats in turn),
#   REQBUFS 4, STREAMON, 3 frames, STREAMOFF, REQBUFS 0: every start delivers
#   frames; reports start-to-first-frame and STREAMOFF times.
# - underrun: all buffers dequeued and none queued for 500 ms (the engine
#   waits at an unarmed slot), then 1 and 2 requeued: each completes fully
#   overwritten, and 120 more frames stream normally.
# - 1 buffer only: 60 frames, each overwritten (an underrun after every frame).
# - afterwards I2C bus 1 still reads both chip IDs (every stop resets the
#   FPGA reset domains).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cap=$(gc573_cap_build "$tmp") || fail "cannot build gc573-cap"

gc573_load || fail "insmod failed"
dev=$(gc573_video_dev) || { gc573_unload; fail "no video node"; }
bus1=
for a in /sys/bus/pci/devices/"$GC573_BDF"/i2c-*; do
	[ "$(cat "$a/name")" = "gc573 $GC573_BDF bus 1" ] && bus1=/dev/${a##*/}
done
rc=0
echo "== start/stop cycles"
"$cap" -d "$dev" -f all -b 4 -n 3 -c "${GC573_CYCLES:-100}" 2>&1 |
	sed 's/^/  /'
[ "${PIPESTATUS[0]}" = 0 ] || rc=1
echo "== underrun"
"$cap" -d "$dev" -f NV12 -b 4 -u -D "$(gc573_debugfs)" 2>&1 | sed 's/^/  /'
[ "${PIPESTATUS[0]}" = 0 ] || rc=1
echo "== one buffer"
"$cap" -d "$dev" -f YUYV -b 1 -n 60 -p 2>&1 | sed 's/^/  /'
[ "${PIPESTATUS[0]}" = 0 ] || rc=1
echo "== I2C bus 1 after the stops"
python3 "$GC573_TESTS/i2c-id-reads.py" "$bus1" 20 2>&1 | sed 's/^/  /'
[ "${PIPESTATUS[0]}" = 0 ] || rc=1
gc573_unload || fail "rmmod failed"
[ "$rc" = 0 ] || fail "see above"
