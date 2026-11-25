#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M1: I2C bus 1 under load, read-only. Two processes read the HDMI chip ID
# registers through i2c-dev at the same time (I2C_RDWR and SMBus emulation,
# GC573_I2C_ROUNDS rounds of 10 transfers each), checking every byte, while
# the driver polls the HDMI chips on the same bus (M3). Each transfer must
# raise exactly one interrupt (INT bit 11): interrupts = reader transfers +
# the driver's transfers (debugfs counter, read around the interrupt count:
# up to 2 at the edges, plus retried transfers). Then a plain read with no
# register write, which the engine cannot do, must be refused with
# EOPNOTSUPP before it reaches the hardware (no interrupt).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

rounds=${GC573_I2C_ROUNDS:-200}
reader="$GC573_TESTS/i2c-id-reads.py"

irq_count() {
	awk '/ gc573$/ { n = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) n += $i; print n }' \
		/proc/interrupts
}

gc573_load || fail "insmod failed"
trap 'gc573_loaded && gc573_unload' EXIT

dev=""
for a in /sys/bus/pci/devices/"$GC573_BDF"/i2c-*; do
	[ "$(cat "$a/name")" = "gc573 $GC573_BDF bus 1" ] && dev=/dev/$(basename "$a")
done
[ -c "$dev" ] || fail "no i2c-dev node for bus 1"
echo "bus 1: $dev"

out1=$(mktemp)
out2=$(mktemp)
x0=$(gc573_hdmi_stat xfers)
r0=$(gc573_hdmi_stat retries)
n0=$(irq_count)
start=$(date +%s%N)
python3 "$reader" "$dev" "$rounds" > "$out1" 2>&1 &
p1=$!
python3 "$reader" "$dev" "$rounds" > "$out2" 2>&1 &
p2=$!
wait "$p1"
rc1=$?
wait "$p2"
rc2=$?
ms=$((($(date +%s%N) - start) / 1000000))
n1=$(irq_count)
x1=$(gc573_hdmi_stat xfers)
r1=$(gc573_hdmi_stat retries)
sed 's/^/reader 1: /' "$out1"
sed 's/^/reader 2: /' "$out2"
rm -f "$out1" "$out2"
xfers=$((2 * rounds * 10))
drv=$((x1 - x0))
extra=$((n1 - n0 - xfers - drv))
echo "$xfers reader transfers in $ms ms, driver transfers $drv (retries $((r1 - r0))), $((n1 - n0)) interrupts (difference $extra)"
[ "$rc1" = 0 ] && [ "$rc2" = 0 ] || fail "reader error or mismatch"
[ "$drv" -gt 0 ] || fail "the driver did not poll during the test"
[ "$extra" -ge -2 ] && [ "$extra" -le $((2 + r1 - r0)) ] ||
	fail "interrupts != transfers"

x1=$(gc573_hdmi_stat xfers)
n1=$(irq_count)
python3 "$reader" "$dev" --plain-read || fail "plain read not refused"
n2=$(irq_count)
x2=$(gc573_hdmi_stat xfers)
extra=$((n2 - n1 - (x2 - x1)))
echo "plain read: $((n2 - n1)) interrupts, driver transfers $((x2 - x1)) (difference $extra)"
[ "$extra" -le 0 ] || fail "plain read raised an interrupt"
echo "plain read refused before the hardware (no interrupt)"
