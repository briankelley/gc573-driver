#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M3: HDMI front-end bring-up at probe (spec/hdmi-chips.md "Bring-up order"):
# both chip IDs, the IT6805 init with its factory trim, the splitter init with
# its reference clock, the default EDID in both RAMs; then the poll worker
# runs for GC573_POLL_SECS (default 5) without I2C errors, retries or
# resyncs. Prints the chips' state from debugfs. Works with or without a
# source on HDMI IN.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

secs=${GC573_POLL_SECS:-5}
tag=$(kmsg_mark hdmi-bringup)
gc573_load || fail "insmod failed"
sleep "$secs"
dbg=$(cat "$(gc573_hdmi_debugfs)")
gc573_unload || fail "rmmod failed"
log=$(kmsg_since "$tag")

echo "$dbg" | sed 's/^/  | /'
for want in ": I2C bus 1 0x90 (IT6805): id 54 49 05 68 rev " \
	    ": I2C bus 1 0x58 (splitter): id 54 49 63 66 rev " \
	    ": IT6805 rev 0x[0-9a-f]*: factory [0-9]* kHz, trim " \
	    ": splitter rev 0x[0-9a-f]*: rclk [0-9]* kHz"; do
	line=$(echo "$log" | grep -e "$want" | head -1)
	[ -n "$line" ] || fail "no log line matching '$want'"
	echo "log: ${line#*: }"
done

stat() { echo "$dbg" | sed -n "s/^hdmi:.* $1 \\([0-9]*\\).*/\\1/p"; }
polls=$(stat polls)
echo "polls $polls in ${secs} s, transfers $(stat xfers), errors $(stat xfer_errors), retries $(stat retries), resyncs $(stat resyncs), poll errors $(stat poll_errors), longest poll $(stat poll_ms_max) ms"
[ "${polls:-0}" -ge $((secs * 10)) ] || fail "too few polls"
[ "$(stat xfer_errors)" = 0 ] && [ "$(stat retries)" = 0 ] &&
	[ "$(stat resyncs)" = 0 ] && [ "$(stat poll_errors)" = 0 ] ||
	fail "I2C errors"
echo "$dbg" | grep -q 'edid_loaded 1' || fail "splitter EDID not loaded"
