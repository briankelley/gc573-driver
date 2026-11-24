#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M2 gate: with no HDMI input the FPGA free-runs at 60 Hz (spec/video-dma.md).
# 1. Default timings (1080p60): each of the six formats, GC573_FRAMES
#    (default 120) frames, every buffer filled with a fresh pattern before
#    each QBUF: after DQBUF every 32-byte block (the DMA length unit) of
#    every plane, one DMA channel per plane, must have been overwritten.
# 2. Every DV timing the driver enumerates x six formats, GC573_SWEEP_FRAMES
#    (default 30) frames each, same checks: each offered mode must work.
# No sequence gaps or error flags. Cadence (no input: 60 Hz whatever the
# timings): mean interval 16.6-16.75 ms, every interval 15-18.4 ms.
# Logs the FPGA input registers (no input: 1010 reads 0xffffffff) and what
# the hardware wrote (the most common word per plane).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cap=$(gc573_cap_build "$tmp") || fail "cannot build gc573-cap"

gc573_load || fail "insmod failed"
dev=$(gc573_video_dev) || { gc573_unload; fail "no video node"; }
echo "device: $dev"
echo "FPGA input registers before streaming:"
gc573_input_regs | sed 's/^/  /'
"$cap" -d "$dev" -f all -b 4 -n "${GC573_FRAMES:-120}" -p > "$tmp/gate" 2>&1
rc1=$?
"$cap" -d "$dev" -f all -b 4 -n "${GC573_SWEEP_FRAMES:-30}" -p -T all \
	> "$tmp/sweep" 2>&1
rc2=$?
echo "FPGA input registers after streaming:"
gc573_input_regs | sed 's/^/  /'
gc573_unload || fail "rmmod failed"

echo "== default timings"
sed 's/^/  /' "$tmp/gate"
echo "== every enumerated DV timing"
grep -E '^(TIMINGS|RESULT|FAIL)' "$tmp/sweep" |
	sed -E 's/ ch[0-9]_bytes=[0-9]+//g; s/^/  /'
[ "$rc1" = 0 ] || fail "default timings: gc573-cap exit $rc1"
[ "$rc2" = 0 ] || fail "timings sweep: gc573-cap exit $rc2"

n=$(grep -c '^RESULT capture ' "$tmp/gate")
[ "$n" = 6 ] || fail "$n formats captured at the default timings, expected 6"
nt=$(grep -c '^TIMINGS ' "$tmp/sweep")
n=$(grep -c '^RESULT capture ' "$tmp/sweep")
[ "$nt" -gt 0 ] && [ "$n" = $((nt * 6)) ] ||
	fail "sweep: $n captures for $nt timings, expected $((nt * 6))"
cat "$tmp/gate" "$tmp/sweep" | awk '/^RESULT capture / {
	for (i = 3; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
	if (v["ivl_ms_mean"] < 16.6 || v["ivl_ms_mean"] > 16.75 ||
	    v["min"] < 15 || v["max"] > 18.4) {
		print "cadence out of range: " $3 " " $4; bad = 1
	}
} END { exit bad }' || fail "frame cadence"
echo "pattern: every plane of every frame overwritten, 6 formats x $nt timings"
echo "cadence: mean 16.6-16.75 ms, all intervals 15-18.4 ms"
