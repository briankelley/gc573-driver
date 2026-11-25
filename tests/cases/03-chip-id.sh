#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M1 gate: the probe reads the HDMI chip IDs on I2C bus 1 (read-only) and logs
# them. Registers 0x00-0x03 must read 54 49 05 68 at 0x90 (IT6805) and
# 54 49 63 66 at 0x58 (splitter), spec/i2c.md. The test compares the bytes
# itself, not the driver's OK/MISMATCH verdict. Also checks that all three
# adapters registered and that bus 0/2 transfers are off.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

tag=$(kmsg_mark chip-id)
gc573_load || fail "insmod failed"
param=$(cat "/sys/module/$GC573_MOD/parameters/i2c_bus02")
adapters=$(for a in /sys/bus/pci/devices/"$GC573_BDF"/i2c-*; do
	[ -e "$a" ] && cat "$a/name"
done)
irqs=$(awk '/gc573/ { n = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) n += $i; print n }' /proc/interrupts)
gc573_unload || fail "rmmod failed"
log=$(kmsg_since "$tag")

echo "adapters:"
echo "$adapters" | sed 's/^/  /'
[ "$(echo "$adapters" | grep -c "^gc573 $GC573_BDF bus [012]$")" = 3 ] ||
	fail "expected 3 gc573 I2C adapters"
[ "$param" = N ] || fail "i2c_bus02 is '$param', expected N"
echo "bus 0/2 transfers: off (i2c_bus02=$param)"
echo "interrupts until unload: $irqs (chip init and HDMI polling)"

ok=0
for want in "0x90 (IT6805): id 54 49 05 68" "0x58 (splitter): id 54 49 63 66"; do
	if echo "$log" | grep -q ": I2C bus 1 $want "; then
		echo "match: $want"
		ok=$((ok + 1))
	else
		echo "no match: $want"
		echo "$log" | grep ': I2C bus 1 0x' | sed 's/^/  got: /'
	fi
done
[ "$ok" = 2 ] || fail "chip IDs"
