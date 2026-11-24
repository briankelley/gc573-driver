#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M0 gate: load/unload x50 (GC573_ITER). Every probe must bind the card and log
# the FPGA version; every remove must unbind it. run.sh scans the kernel log of
# the whole loop for warnings, sanitizer, lockdep and DMA-API reports and driver
# errors, and kmemleak covers it at the end of the suite.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

n=${GC573_ITER:-50}
start=$(date +%s)
for i in $(seq 1 "$n"); do
	tag=$(kmsg_mark "iteration $i")
	gc573_load || fail "iteration $i: insmod failed"
	if ! gc573_bound; then
		gc573_unload
		fail "iteration $i: not bound"
	fi
	gc573_unload || fail "iteration $i: rmmod failed"
	gc573_bound && fail "iteration $i: still bound after rmmod"
	kmsg_since "$tag" | grep -q ': FPGA version ' ||
		fail "iteration $i: no FPGA version line"
done
echo "$n load/unload cycles in $(($(date +%s) - start)) s"
