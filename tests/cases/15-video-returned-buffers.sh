#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M2 review: DMA never writes into a buffer that userspace holds. gc573-cap -R
# with NV12 at the current timings, 3 buffers, GC573_RB_QBUFS (default 6000)
# QBUFs: each dequeued buffer is filled with a fresh pattern, held 0-20 ms at
# random and checked before it is queued again, so QBUFs land at random
# points of the frame. Guards the arming rule of gc573_buf_queue(): a ch0
# CH_CTRL read-modify-write that straddles a slot completion would arm the
# completed slot again. Also no completion for an unarmed slot (debugfs).
# No input (gc573_input_off): a lock would end the stream.
# A 200000-QBUF run of the code before the rule did not reproduce the race:
# tests/logs/20261125-001400_6.8.0-151-generic_rbtest.log.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cap=$(gc573_cap_build "$tmp") || fail "cannot build gc573-cap"

gc573_load || fail "insmod failed"
dev=$(gc573_video_dev) || { gc573_unload; fail "no video node"; }
gc573_input_off "$dev"
"$cap" -d "$dev" -f NV12 -b 3 -R "${GC573_RB_QBUFS:-6000}" \
	-D "$(gc573_debugfs)" > "$tmp/out" 2>&1
rc=$?
gc573_unload || fail "rmmod failed"

grep -E '^(INFO|RESULT|FAIL)' "$tmp/out" | sed 's/^/  /'
grep '^  | stats:' "$tmp/out" | sed 's/^/  /'
[ "$rc" = 0 ] || fail "gc573-cap exit $rc"
grep -q '^RESULT rbtest .* buffers_changed=0 ' "$tmp/out" ||
	fail "DMA wrote into a dequeued buffer"
grep -q '^  | stats: .* unarmed 0 ' "$tmp/out" ||
	fail "completion for an unarmed slot"
