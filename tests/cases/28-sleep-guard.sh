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
#   capture and an audio read work (no stream start stays blocked);
# - a teardown's stop in progress (final review F2, F4): an unbind with
#   exp_stop_fault bit 7, which holds the stop's verdict 2 s once the stop
#   is done (confirmed: no other bit; setting it taints the kernel), and
#   power/control at auto from before the unbind. Within the hold the card
#   must be runtime active (the driver's usage count, from the probe to
#   the teardown's end: the PCI core drops its own before the teardown,
#   and the card and the port above it could suspend under the stop), and
#   a system sleep must be refused, by the driver, for the stop not
#   confirmed yet: its "suspend entry" line and the refusal inside the
#   hold. The unbind then ends with the card not dead, bus mastering on
#   and the PCI enable count at 1.
# pm_test and power/control are put back. SKIP without /sys/power/pm_test
# or the freeze state.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

[ -w /sys/power/pm_test ] && grep -qw freeze /sys/power/state ||
	skip "no /sys/power/pm_test or no freeze state"
work=$(mktemp -d)
cap=$(gc573_cap_build "$work") || fail "cannot build gc573-cap"
aud=$(gc573_aud_build "$work") || fail "cannot build gc573-aud"
pids=()
pdev=/sys/bus/pci/devices/$GC573_BDF
param=/sys/module/$GC573_MOD/parameters/exp_stop_fault
ctl0=$(cat "$pdev/power/control")

cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	wait 2>/dev/null
	[ -w "$param" ] && echo 0 > "$param"
	echo none > /sys/power/pm_test
	echo "$ctl0" > "$pdev/power/control"
	gc573_loaded && gc573_unload
	rm -rf "$work"
}

{
	echo 'system sleep refused: (a video|an audio) stream is on'
	echo 'system sleep refused: [0-9]+ DMA stop\(s\) not confirmed yet'
} >> "$GC573_KMSG_ALLOW"

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

echo "-- unbind, the teardown's stop confirmed and its verdict held 2 s; power/control auto"
[ -w "$param" ] || fail "no exp_stop_fault parameter"
tag=$(kmsg_mark "sleep guard: teardown stop held")
echo 128 > "$param" || fail "cannot set exp_stop_fault"
kmsg_since "$tag" | grep -q 'Setting dangerous option exp_stop_fault - tainting kernel' ||
	fail "setting exp_stop_fault did not taint the kernel"
echo auto > "$pdev/power/control" || fail "cannot set power/control to auto"
timeout 60 sh -c "echo $GC573_BDF > /sys/bus/pci/drivers/$GC573_MOD/unbind" &
upid=$!
pids+=("$upid")
for i in $(seq 100); do
	kmsg_since "$tag" | grep -q 'the teardown stop holds its verdict for [0-9]* ms' && break
	kill -0 "$upid" 2>/dev/null || break
	sleep 0.05
done
held=$(kmsg_since "$tag" | grep -c 'the teardown stop holds its verdict for [0-9]* ms')
rs=$(cat "$pdev/power/runtime_status")
port=$(readlink -f "$pdev/..")
ps=$(cat "$port/power/runtime_status" 2>/dev/null)
gc573_sleep_test > "$work/sleep3.out"
src=$?
wait "$upid"
rc=$?
pids=()
echo 0 > "$param"
echo "$ctl0" > "$pdev/power/control"
kmsg_since "$tag" | grep -E 'exp_stop_fault|PM: suspend|system sleep refused|teardown stop' | sed 's/^/  | /'
[ "$held" -ge 1 ] || fail "the stop's verdict was not held (a driver without exp_stop_fault bit 7)"
[ $rc = 0 ] || fail "unbind did not finish"
echo "during the hold: the card runtime $rs, its port ${port##*/} $ps"
t0=$(kmsg_since "$tag" | sed -n 's/^\[ *\([0-9.]*\)\].*: exp_stop_fault 0x[0-9a-f]*: the teardown stop holds its verdict for .*/\1/p' | head -1)
t1=$(kmsg_since "$tag" | sed -n 's/^\[ *\([0-9.]*\)\] PM: suspend entry .*/\1/p' | head -1)
bad=""
[ "$rs" = active ] || bad+="the card was runtime $rs during the teardown's stop (no usage count of the driver's); "
case $src in
0) bad+="system sleep went through the freezer stage while the teardown's stop was not confirmed; " ;;
1)
	if kmsg_since "$tag" | grep -qE 'system sleep refused: [0-9]+ DMA stop\(s\) not confirmed yet'; then
		echo "system sleep refused during the hold: $(cat "$work/sleep3.out")"
	else
		bad+="the sleep was refused, but not by the driver for the stop in progress; "
	fi
	;;
*) bad+="pm_test: the sleep could not be tried; " ;;
esac
if [ -n "$t0" ] && [ -n "$t1" ]; then
	awk -v a="$t0" -v b="$t1" 'BEGIN { exit !(a < b && b < a + 2) }' ||
		bad+="the sleep did not start inside the hold (hold at $t0 s, entry $t1 s): not judged; "
else
	bad+="a line is missing: the hold '$t0', the sleep's entry '$t1'; "
fi
[ -z "$(gc573_dead_cards)" ] || bad+="the card is dead after a confirmed stop; "
gc573_master_on || bad+="bus mastering off after the unbind; "
x=$(cat "$pdev/enable")
[ "$x" = 1 ] || bad+="PCI enable count $x after the unbind, not 1; "
[ -z "$bad" ] || fail "${bad%; }"
echo "held teardown stop: runtime active, sleep refused; then unbound, not dead, bus mastering on, PCI enable count $x"
