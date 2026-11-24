#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M0: probe binds the card, uses MSI and logs the FPGA VERSION register; remove
# quiesces (INT_ENABLE reads 0) and unbinds. Loads with dynamic debug on, so the
# log keeps the init and quiesce register readbacks.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

tag=$(kmsg_mark probe)
gc573_load dyndbg=+p || fail "insmod failed"
if ! gc573_bound; then
	gc573_unload
	fail "$GC573_BDF not bound"
fi
gc573_unload || fail "rmmod failed"
gc573_bound && fail "$GC573_BDF still bound after rmmod"

log=$(kmsg_since "$tag")
ver=$(echo "$log" | sed -n 's/.*: FPGA version \([0-9a-f]\{8\}\)$/\1/p')
[ -n "$ver" ] || fail "no FPGA version line"
echo "FPGA version $ver (spec/regmap.md: 20200811)"

echo "$log" | grep -q ': using MSI, irq ' || fail "not using MSI"
echo "MSI in use"

if echo "$log" | grep -q ': state at probe: '; then
	echo "$log" | grep -q ': quiesced: INT_ENABLE=0x00000000 ' ||
		fail "quiesce readback missing or INT_ENABLE != 0"
	echo "quiesce: INT_ENABLE reads 0 after remove"
else
	echo "no dynamic debug output: quiesce readback not checked"
fi
