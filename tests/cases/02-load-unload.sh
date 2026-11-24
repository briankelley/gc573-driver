#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M0 gate: load/unload x50 (GC573_ITER). Every probe must bind the card, log
# the FPGA version and (M1) read both HDMI chip IDs OK over I2C bus 1; every
# remove must unbind it. run.sh scans the kernel log of the whole loop for
# warnings, sanitizer, lockdep and DMA-API reports and driver errors, and
# kmemleak covers it at the end of the suite.
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
	log=$(kmsg_since "$tag")
	echo "$log" | grep -q ': FPGA version ' ||
		fail "iteration $i: no FPGA version line"
	[ "$(echo "$log" | grep -c ': I2C bus 1 0x[0-9a-f]* (.*): id .* OK$')" = 2 ] ||
		fail "iteration $i: chip IDs not both OK"
done
echo "$n load/unload cycles in $(($(date +%s) - start)) s"
