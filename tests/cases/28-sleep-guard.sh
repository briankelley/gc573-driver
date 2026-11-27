#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# No system sleep while the card streams. For a driver without PM
# callbacks the PCI core turns bus mastering off at a suspend, a
# hibernation and the restore of an image (pci_pm_default_suspend()),
# whatever the card does, and spec/pci.md forbids that while its DMA may
# run. With /sys/power/pm_test at "freezer" the PM notifiers run, then
# the tasks freeze for pm_test_delay (5 s) and thaw: no device sees a
# suspend. Then:
# - while a video stream runs, and again while an audio stream runs,
#   "freeze" is refused (the write fails) and the driver says why;
# - with the card idle it goes through, and afterwards a pattern-checked
#   capture and an audio read work (no stream start stays blocked).
# pm_test is put back. SKIP without /sys/power/pm_test or the freeze state.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

[ -w /sys/power/pm_test ] && grep -qw freeze /sys/power/state ||
	skip "no /sys/power/pm_test or no freeze state"
work=$(mktemp -d)
cap=$(gc573_cap_build "$work") || fail "cannot build gc573-cap"
aud=$(gc573_aud_build "$work") || fail "cannot build gc573-aud"
pids=()

cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	wait 2>/dev/null
	echo none > /sys/power/pm_test
	gc573_loaded && gc573_unload
	rm -rf "$work"
}

echo 'system sleep refused: (a video|an audio) stream is on' >> "$GC573_KMSG_ALLOW"

# A stream program is running ($1: pid), then sleep is refused for it
# ($2: what the driver names); the program is stopped after
refused_while() {
	local tag rc
	sleep 2
	kill -0 "$1" 2>/dev/null || fail "the stream ended before the sleep"
	tag=$(kmsg_mark "sleep guard: $2")
	gc573_sleep_test > "$work/sleep.out"
	rc=$?
	[ $rc = 1 ] || fail "sleep with $2 on: status $rc ($(cat "$work/sleep.out"))"
	kmsg_since "$tag" | grep "$GC573_MOD" | sed 's/^/  | /'
	kmsg_since "$tag" | grep -q "system sleep refused: $2 is on" ||
		fail "sleep refused, but not by the driver for $2"
	kill -0 "$1" 2>/dev/null || fail "the stream ended at the refused sleep"
	echo "$2: sleep refused ($(cat "$work/sleep.out"))"
	kill "$1"
	wait "$1" 2>/dev/null
	pids=()
}

gc573_load || fail "insmod failed"
trap cleanup EXIT
vdev=$(gc573_video_dev) || fail "no video device"
gc573_input_off "$vdev"

"$cap" -d "$vdev" -n 100000 > "$work/cap.log" 2>&1 &
pids+=($!)
refused_while "${pids[0]}" "a video stream"

"$aud" -t 60 > "$work/aud.log" 2>&1 &
pids+=($!)
refused_while "${pids[0]}" "an audio stream"

tag=$(kmsg_mark "sleep guard: idle")
gc573_sleep_test > "$work/sleep.out"
rc=$?
kmsg_since "$tag" | grep -E "$GC573_MOD|PM: |suspend debug" | sed 's/^/  | /'
[ $rc = 0 ] || fail "sleep with the card idle: status $rc ($(cat "$work/sleep.out"))"
"$cap" -d "$vdev" -n 30 -p > "$work/cap2.log" 2>&1 ||
	{ cat "$work/cap2.log"; fail "capture after the sleep failed"; }
"$aud" -t 1 > "$work/aud2.log" 2>&1 ||
	{ cat "$work/aud2.log"; fail "audio after the sleep failed"; }
echo "idle: sleep through the freezer stage; then 30 frames pattern-checked and an audio read"
