#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Experiment, spec/open-questions.md #8: which CH_CTRL slot-valid bits the DMA
# honours, with no input, NV12 (ch0 + ch1) and YV12 (ch0 + ch1 + ch2). Uses the
# driver's exp_slot_mode parameter (read at stream start):
#   1  slot-valid bits on ch0 only (ch1/ch2: run bit only)
#   2  ch1/ch2 CH_CTRL written once at start (all armed slots + run), never again
#   4  ch1/ch2 CH_CTRL never written
#   5  ch1/ch2 CH_CTRL = 0 at start (no run bit, no slot bits), never set
#      result 2026-11: every plane of every frame written -> expect the same
#   3  slot-valid bits on ch1/ch2 only, ch0 run bit only
#      result 2026-11: no frame completes, no plane written -> expect the same
# Mode 4 alone would not show that ch1/ch2 CH_CTRL are ignored (they cannot
# be read back, and earlier streams wrote them); mode 5 writes them 0.
# A FAIL here means the hardware answered differently from the recorded
# result (another FPGA version?), not necessarily a driver bug.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

param=/sys/module/$GC573_MOD/parameters/exp_slot_mode
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cap=$(gc573_cap_build "$tmp") || fail "cannot build gc573-cap"

gc573_load || fail "insmod failed"
dev=$(gc573_video_dev) || { gc573_unload; fail "no video node"; }
bad=
for m in 1 2 4 5; do
	echo "$m" > "$param"
	for f in NV12 YV12; do
		out=$("$cap" -d "$dev" -f "$f" -b 4 -n 60 -p 2>&1)
		rc=$?
		echo "mode $m $f: exit $rc"
		echo "$out" | grep -E '^(RESULT|FAIL)' | sed 's/^/  /'
		[ "$rc" = 0 ] || bad="$bad $m/$f"
	done
done
echo 3 > "$param"
for f in NV12 YV12; do
	out=$("$cap" -d "$dev" -f "$f" -b 4 -w 500 -D "$(gc573_debugfs)" 2>&1)
	echo "mode 3 $f:"
	echo "$out" | grep -E '^RESULT|stats:' | sed 's/^/  /'
	# every buffer, every plane: all blocks still hold the pattern
	echo "$out" | grep '^RESULT wait' | tr ' ' '\n' | grep untouched= |
		awk -F'[=/]' '$2 != $3 { bad = 1 } END { exit bad }' ||
		bad="$bad 3/$f(written)"
	echo "$out" | grep -q 'stats: irqs 0 frames 0 ' || bad="$bad 3/$f(frames)"
done
echo 0 > "$param"
gc573_unload || fail "rmmod failed"
[ -z "$bad" ] || fail "differs from the recorded result:$bad"
echo "ch0 CH_CTRL (run, slot-valid bits) gates every channel; ch1/ch2 CH_CTRL had no visible effect"
