#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M0 gate: load/unload x50 (GC573_ITER). Every probe must bind the card, log
# the FPGA version and both HDMI chip IDs read over I2C bus 1 (M1; since M3
# the front-end bring-up reads them, and a wrong ID fails the probe); every
# remove must unbind it. The driver never turns bus mastering off (final
# review F1: then a probe that finds it off knows another owner did, and
# spec/pci.md forbids turning it on again over a card whose DMA may have
# been cut): every unload must leave it on, with the device's PCI enable
# count at 1 (the driver's own enable, taken once), and 2 while bound, so
# that it does not grow from one cycle to the next. run.sh scans the
# kernel log of the whole loop for warnings, sanitizer, lockdep and
# DMA-API reports and driver errors, and kmemleak covers it at the end of
# the suite.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

n=${GC573_ITER:-50}
en=/sys/bus/pci/devices/$GC573_BDF/enable
start=$(date +%s)
for i in $(seq 1 "$n"); do
	tag=$(kmsg_mark "iteration $i")
	gc573_load || fail "iteration $i: insmod failed"
	if ! gc573_bound; then
		gc573_unload
		fail "iteration $i: not bound"
	fi
	e1=$(cat "$en")
	gc573_unload || fail "iteration $i: rmmod failed"
	gc573_bound && fail "iteration $i: still bound after rmmod"
	e2=$(cat "$en")
	gc573_master_on || fail "iteration $i: bus mastering off after the unload (the driver turned it off)"
	[ "$e1" = 2 ] && [ "$e2" = 1 ] ||
		fail "iteration $i: PCI enable count $e1 bound, $e2 after the unload (want 2 and 1)"
	log=$(kmsg_since "$tag")
	grep -q ': FPGA version ' <<< "$log" ||
		fail "iteration $i: no FPGA version line"
	for want in "0x90 (IT6805): id 54 49 05 68" "0x58 (splitter): id 54 49 63 66"; do
		grep -q ": I2C bus 1 $want rev " <<< "$log" ||
			fail "iteration $i: no '$want' line"
	done
done
echo "$n load/unload cycles in $(($(date +%s) - start)) s; after each unload bus mastering on, PCI enable count 1"
