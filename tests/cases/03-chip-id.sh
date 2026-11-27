#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M1 gate: the probe reads the HDMI chip IDs on I2C bus 1 (read-only) and logs
# them. Registers 0x00-0x03 must read 54 49 05 68 at 0x90 (IT6805) and
# 54 49 63 66 at 0x58 (splitter), spec/i2c.md. The test compares the bytes
# itself, not the driver's OK/MISMATCH verdict. The I2C adapters (i2c-dev
# nodes) exist only with their parameters (fix review N4): none by default,
# bus 1 alone with i2c_bus1=1, buses 0 and 2 alone with i2c_bus02=1.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

# The card's I2C adapters while loaded with parameters "$@", one name per
# line; unloads again
adapters() {
	local a
	gc573_load "$@" || fail "insmod $* failed"
	for a in /sys/bus/pci/devices/"$GC573_BDF"/i2c-*; do
		[ -e "$a" ] && cat "$a/name"
	done
	gc573_unload || fail "rmmod failed"
}

tag=$(kmsg_mark chip-id)
gc573_load || fail "insmod failed"
p1=$(cat "/sys/module/$GC573_MOD/parameters/i2c_bus1")
p02=$(cat "/sys/module/$GC573_MOD/parameters/i2c_bus02")
none=$(for a in /sys/bus/pci/devices/"$GC573_BDF"/i2c-*; do
	[ -e "$a" ] && cat "$a/name"
done)
irqs=$(awk '/gc573/ { n = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) n += $i; print n }' /proc/interrupts)
gc573_unload || fail "rmmod failed"
log=$(kmsg_since "$tag")

[ -z "$none" ] || fail "I2C adapters without their parameters: $(tr '\n' ';' <<< "$none")"
[ "$p1" = N ] && [ "$p02" = N ] || fail "defaults: i2c_bus1 '$p1', i2c_bus02 '$p02', expected N and N"
echo "by default: no I2C adapters (i2c_bus1=$p1 i2c_bus02=$p02)"
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

got=$(adapters i2c_bus1=1)
echo "i2c_bus1=1: $(tr '\n' ';' <<< "$got")"
[ "$got" = "gc573 $GC573_BDF bus 1" ] || fail "i2c_bus1=1: expected bus 1 alone"
got=$(adapters i2c_bus02=1 | sort)
echo "i2c_bus02=1: $(tr '\n' ';' <<< "$got")"
[ "$got" = "gc573 $GC573_BDF bus 0"$'\n'"gc573 $GC573_BDF bus 2" ] ||
	fail "i2c_bus02=1: expected buses 0 and 2 alone"
