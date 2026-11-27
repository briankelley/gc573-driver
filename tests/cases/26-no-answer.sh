#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# A card that does not answer (fix review N2, and the probe's check after
# bus mastering), with the test parameter exp_mmio_ones: from a point of
# the probe on, every register read returns all-ones, as from a card that
# does not answer MMIO. Setting it must taint the kernel
# (module_param_unsafe). Each mode, with the device unbound, then a bind:
# 1 from the probe's start: the probe refuses the card ("does not
#   answer", -ENODEV) and, bus mastering being off when it started, leaves
#   it off; nothing of the device is left and nothing is kept.
# 2 for 1.5 s once bus mastering is on: the probe waits for VERSION to
#   read as it did before, says how long that took ("answers again"), and
#   the card works (a pattern-checked capture).
# After each, a bind with the parameter off brings the card back.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

param=/sys/module/$GC573_MOD/parameters/exp_mmio_ones
drv=/sys/bus/pci/drivers/$GC573_MOD
pdev=/sys/bus/pci/devices/$GC573_BDF
work=$(mktemp -d)
cap=$(gc573_cap_build "$work") || fail "cannot build gc573-cap"

cleanup() {
	[ -w "$param" ] && echo 0 > "$param"
	gc573_loaded && gc573_unload
	rm -rf "$work"
}

{
	echo 'since bus mastering went on \([0-9a-f]+ before\): the card is not ready; waiting up to 20 s'
} >> "$GC573_KMSG_ALLOW"

# What a failed probe left of the device (nothing: empty)
leftovers() {
	local f x
	for f in "$pdev"/video4linux/video* "$pdev"/sound/card* "$pdev"/i2c-*; do
		[ -e "$f" ] && echo "${f#"$pdev"/}"
	done
	[ -e "/sys/kernel/debug/$GC573_MOD-$GC573_BDF" ] && echo "debugfs $GC573_MOD-$GC573_BDF"
	grep -w "$GC573_MOD" /proc/interrupts | awk '{ print "IRQ " $1 }'
	x=$(find "$pdev/msi_irqs" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
	[ "$x" = 0 ] || echo "MSI vectors: $x"
	x=$(cat "$pdev/enable")
	[ "$x" = 0 ] || echo "PCI enable count $x"
	gc573_master_on && echo "bus mastering on"
}

# The kernel log after tag $1, the lines this case looks at
show() {
	kmsg_since "$1" | grep -E 'exp_mmio_ones|does not answer|bus mastering|answers again|kept until reboot|FPGA version' |
		sed 's/^/  | /'
}

# bound with the video node; input off; a pattern-checked capture
up() {
	local i
	for i in $(seq 100); do
		vdev=$(gc573_video_dev 2>/dev/null) && [ -c "$vdev" ] && break
		sleep 0.1
	done
	[ -c "$vdev" ] || fail "$1: no video node"
	gc573_master_on || fail "$1: bus mastering off"
	gc573_input_off "$vdev"
	"$cap" -d "$vdev" -n 30 -p > "$work/smoke.log" 2>&1 ||
		{ cat "$work/smoke.log"; fail "$1: capture failed"; }
	echo "$1: bound, bus mastering on, 30 frames pattern-checked"
}

gc573_load || fail "insmod failed"
trap cleanup EXIT
[ -w "$param" ] || fail "no exp_mmio_ones parameter (a driver without the checks)"
echo "$GC573_BDF" > "$drv/unbind" || fail "unbind failed"
tag=$(kmsg_mark "no-answer taint")
echo 0 > "$param"
kmsg_since "$tag" | grep -q 'Setting dangerous option exp_mmio_ones - tainting kernel' ||
	fail "setting exp_mmio_ones did not taint the kernel"

echo "-- mode 1: no answer from the probe's start"
gc573_master_on && fail "bus mastering on after the unbind"
tag=$(kmsg_mark "no-answer 1")
echo 1 > "$param" || fail "cannot set exp_mmio_ones 1"
if echo "$GC573_BDF" > "$drv/bind" 2> "$work/bind.err"; then
	fail "mode 1: the bind succeeded"
fi
echo 0 > "$param"
echo "mode 1: bind refused ($(sed 's/^.*: //' "$work/bind.err"))"
show "$tag"
left=$(leftovers)
[ -z "$left" ] || fail "mode 1: left behind: $(tr '\n' ';' <<< "$left")"
kmsg_since "$tag" | grep -q ': the card does not answer (VERSION ffffffff .*): not used$' ||
	fail "mode 1: no 'does not answer' line"
! kmsg_since "$tag" | grep -q 'kept until reboot' || fail "mode 1: memory kept, but the card was never given any"
echo "$GC573_BDF" > "$drv/bind" || fail "bind after mode 1 failed"
up "bind after mode 1"
echo "$GC573_BDF" > "$drv/unbind" || fail "unbind after mode 1 failed"

echo "-- mode 2: no answer for 1.5 s once bus mastering is on"
tag=$(kmsg_mark "no-answer 2")
echo 2 > "$param"
echo "$GC573_BDF" > "$drv/bind" || fail "mode 2: bind failed"
echo 0 > "$param"
show "$tag"
ms=$(kmsg_since "$tag" | sed -n 's/.*the card answers again, \([0-9]*\) ms after bus mastering went on/\1/p')
[ -n "$ms" ] || fail "mode 2: no 'answers again' line"
[ "$ms" -ge 1400 ] && [ "$ms" -le 3000 ] || fail "mode 2: answered after $ms ms, expected about 1500"
up "mode 2"
echo "both modes refused or waited as they should, and the card came back after each"
