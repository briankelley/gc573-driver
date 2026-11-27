#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# What i2c-dev may do on I2C bus 1, the HDMI chips' bus (security review
# of a0adb1d, F8):
# - only the chips' addresses (src/gc573_i2c.c): reads and writes to 0x37
#   (DDC/CI, which monitor tools probe on every bus) and 0x50 (EDID) fail
#   with EPERM before they reach the bus, while the IT6805's ID still
#   reads 54 49 05 68 at 0x48;
# - an i2c-dev write that selects another bank (IT6805 0x0f = 1) between
#   the driver's sequences: the driver selects every bank again before its
#   next use (debugfs hdmi "resyncs" goes up), and leaves the IT6805 in
#   bank 0 again, as its chip code expects it.
# The bank part runs only after the address part passed: an older driver
# would go on in bank 1.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

xfer="python3 $GC573_TESTS/i2c-xfer.py"

gc573_load || fail "insmod failed"
trap 'gc573_loaded && gc573_unload' EXIT
echo 'I2C bus 1: transfer to 0x[0-9a-f]+ refused: not one of the card.s HDMI chips' >> "$GC573_KMSG_ALLOW"

dev=""
for a in /sys/bus/pci/devices/"$GC573_BDF"/i2c-*; do
	[ "$(cat "$a/name")" = "gc573 $GC573_BDF bus 1" ] && dev=/dev/$(basename "$a")
done
[ -c "$dev" ] || fail "no i2c-dev node for bus 1"
echo "bus 1: $dev"
bad=0

# $1: expected output after "ADDR REG: "; the rest: i2c-xfer.py arguments
expect() {
	local want=$1 out
	shift
	out=$($xfer "$dev" "$@")
	if [ "${out#*: }" = "$want" ]; then
		echo "ok:   $out"
	else
		echo "BAD:  $out (expected $want)"
		bad=1
	fi
}

echo "-- addresses"
expect errno=EPERM read 0x37 0x00
expect errno=EPERM read 0x50 0x00 8
expect "54 49 05 68" read 0x48 0x00 4
# writes only once reads are refused: an older driver would send them on
# (0x37 is the splitter's TX port 3)
[ "$bad" = 0 ] || fail "bus 1 reached an address that is not one of the card's chips"
expect errno=EPERM write 0x37 0x51 0x82 0x01 0x10 0xac
expect errno=EPERM write 0x50 0x00 0x00
[ "$bad" = 0 ] || fail "bus 1 took a write to an address that is not one of the card's chips"

echo "-- bank select through i2c-dev"
r0=$(gc573_hdmi_stat resyncs)
expect ok write 0x48 0x0f 0x01
sleep 0.5
r1=$(gc573_hdmi_stat resyncs)
bank=$($xfer "$dev" read 0x48 0x0f)
bank=${bank#*: }
echo "IT6805 0x0f after 0.5 s: $bank; resyncs $r0 -> $r1"
case $bank in
[0-9a-f][0-9a-f]) ;;
*) bank=ff ;;
esac
[ "$((0x$bank & 7))" = 0 ] || { echo "BAD:  the IT6805 is not back in bank 0"; bad=1; }
[ "$r1" -gt "$r0" ] || { echo "BAD:  the driver did not select its banks again"; bad=1; }
[ "$bad" = 0 ] || fail "the driver's bank cache did not follow an i2c-dev bank select"
echo "every check passed"
