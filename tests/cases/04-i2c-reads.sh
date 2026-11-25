#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M1: I2C bus 1 under load, read-only. Two processes read the HDMI chip ID
# registers through i2c-dev at the same time (I2C_RDWR and SMBus emulation,
# GC573_I2C_ROUNDS rounds of 10 transfers each), checking every byte, while
# the driver polls the HDMI chips on the same bus (M3). Each transfer must
# raise exactly one interrupt (INT bit 11): interrupts = reader transfers +
# the driver's transfers. The driver's count (debugfs) is read just before
# and just after the interrupt count, in one process (snap); a poll cycle
# is a burst of some 30-50 transfers, and one that falls between the reads
# moves the two apart, so the check takes the driver's share between the
# inner and the outer pair of reads, 2 more at either edge, plus retried
# transfers. Then a plain read with no register write, which the engine
# cannot do, must be refused with EOPNOTSUPP before it reaches the
# hardware (no interrupt).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

rounds=${GC573_I2C_ROUNDS:-200}
reader="$GC573_TESTS/i2c-id-reads.py"

irq_count() {
	awk '/ gc573$/ { n = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) n += $i; print n }' \
		/proc/interrupts
}

# "XFERS_BEFORE INTERRUPTS XFERS_AFTER", read back to back in one process
snap() {
	awk -v hf="$(gc573_hdmi_debugfs)" '
		FILENAME == hf && /^hdmi:/ {
			for (i = 1; i < NF; i++) if ($i == "xfers") x[++c] = $(i + 1)
		}
		FILENAME == "/proc/interrupts" && / gc573$/ {
			for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) n += $i
		}
		END { print x[1] + 0, n + 0, x[2] + 0 }' \
		"$(gc573_hdmi_debugfs)" /proc/interrupts "$(gc573_hdmi_debugfs)"
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
r0=$(gc573_hdmi_stat retries)
read -r xa0 n0 xb0 < <(snap)
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
read -r xa1 n1 xb1 < <(snap)
r1=$(gc573_hdmi_stat retries)
sed 's/^/reader 1: /' "$out1"
sed 's/^/reader 2: /' "$out2"
rm -f "$out1" "$out2"
xfers=$((2 * rounds * 10))
lo=$((xa1 - xb0))
hi=$((xb1 - xa0))
drv=$((n1 - n0 - xfers))
echo "$xfers reader transfers in $ms ms, $((n1 - n0)) interrupts: $drv for the driver, which made $lo to $hi transfers (edge bursts $((xb0 - xa0)), $((xb1 - xa1)); retries $((r1 - r0)))"
[ "$rc1" = 0 ] && [ "$rc2" = 0 ] || fail "reader error or mismatch"
[ "$lo" -gt 0 ] || fail "the driver did not poll during the test"
[ "$drv" -ge $((lo - 2)) ] && [ "$drv" -le $((hi + 2 + r1 - r0)) ] ||
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
