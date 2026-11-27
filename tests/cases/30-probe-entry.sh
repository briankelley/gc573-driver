#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# A card that does not read idle when the probe starts with its bus
# mastering off (delta review D1). Bus mastering turned off under a
# running DMA (an older gc573's failed stop, a virtual machine's end
# without a working reset, a kexec) and turned on again by the next probe
# stalled a CPU for some 15 s while the card read all-ones (spec/pci.md):
# a host can hang there. So with bus mastering off at the probe's start
# and the card not idle (the audio DMA or the video output on, or a read
# of all-ones), the probe writes nothing to the card and never turns bus
# mastering on: the card is dead until reboot. An idle card at the same
# point is probed as always. The card itself is idle in every mode: only
# the parameter makes the driver see it otherwise. One mode per run,
# GC573_TEST_ENTRY; each starts with the card bound, then an unbind (which
# turns bus mastering off), BAR0 read idle past the driver, and a bind
# with the parameter set:
# - armed (default): exp_probe_armed, the probe's read of DMA_RUN shows
#   the audio DMA on;
# - ones: exp_mmio_ones 1, every register read all-ones from the probe's
#   start;
# - restop (delta review D10): the card idle, so the probe stops the
#   engines and resets the domains; exp_stop_fault bit 3 then counts the
#   stop, confirmed by DMA_RUN and VIP_CTRL read back idle, as the audio
#   DMA still on.
# Setting the parameter must taint the kernel (module_param_unsafe).
# Then: the bind fails (ENODEV); armed and ones: the probe's line for the
# card not idle with bus mastering off, none for a stop of the engines,
# and no memory kept (the card was given none); restop: the stop's lines
# (confirmed, then counted as not confirmed), and 12 KiB kept (the dummy
# list and the audio buffers, which the stop gave the card); each: the
# line "bus mastering stays off", bus mastering off (PCI_COMMAND bit 2),
# the card in dead_cards, the module not unloadable, no bind (ENODEV),
# system sleep refused (with /sys/power/pm_test, as far as its freezer
# stage), and BAR0, read past the driver, idle. run.sh runs this case
# last and skips the cases after it; the machine needs a reboot after it
# (in a VM: tools/vms/card-idle.sh first). Allowed: the failures this
# case provokes, and under DMA-API debug the report of the driver's DMA
# memory at the unwind.
# gc573-run: last
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

drv=/sys/bus/pci/drivers/$GC573_MOD
pdev=/sys/bus/pci/devices/$GC573_BDF
par=/sys/module/$GC573_MOD/parameters
mode=${GC573_TEST_ENTRY:-armed}
case $mode in
armed) param=$par/exp_probe_armed val=1 ;;
ones) param=$par/exp_mmio_ones val=1 ;;
restop) param=$par/exp_stop_fault val=8 ;;
*) fail "GC573_TEST_ENTRY: armed, ones or restop, not '$mode'" ;;
esac
work=$(mktemp -d)
regs=$(gc573_regs_build "$work") || fail "cannot build gc573-regs"

cleanup() {
	[ -w "$param" ] && echo 0 > "$param"
	[ -w /sys/power/pm_test ] && echo none > /sys/power/pm_test
	[ -n "$(gc573_dead_cards)" ] || { gc573_loaded && gc573_unload; }
	rm -rf "$work"
}
trap cleanup EXIT

{
	echo 'bus mastering was off when the probe started, and the card does not read idle'
	echo 'not idle at the probe.s start with bus mastering off: bus mastering stays off, and the card gets no driver until reboot'
	echo 'exp_probe_armed: DMA_RUN 0x[0-9a-f]+ read as'
	echo 'exp_stop_fault 0x[0-9a-f]+: the probe stop was confirmed'
	echo 'the stop of the engines at probe is not confirmed: DMA still on'
	echo 'the stop of the engines at probe failed: bus mastering stays off, and the card gets no driver until reboot'
	echo 'system sleep refused: 1 card\(s\) did not confirm their DMA stopped'
	echo 'WARNING: CPU: [0-9]+ PID: [0-9]+ at kernel/dma/debug\.c:[0-9]+ dma_debug_device_change'
	echo 'DMA-API: Mapped at:'
} >> "$GC573_KMSG_ALLOW"

gc573_load || fail "insmod failed"
[ -w "$param" ] || fail "no ${param##*/} parameter (a driver without the check)"
[ -e "$par/dead_cards" ] || fail "no dead_cards parameter"
[ -z "$(gc573_dead_cards)" ] || fail "a card is dead already: reboot first"
gc573_bound || fail "$GC573_BDF not bound after the load"
echo "$GC573_BDF" > "$drv/unbind" || fail "unbind failed"
gc573_master_on && fail "bus mastering on after the unbind"
st=$(gc573_regs_idle "$regs") || fail "BAR0 does not read idle after the unbind: $st"
echo "unbound: bus mastering off, BAR0 $st"

tag=$(kmsg_mark "probe-entry $mode")
echo "$val" > "$param" || fail "cannot set ${param##*/}"
kmsg_since "$tag" | grep -q "Setting dangerous option ${param##*/} - tainting kernel" ||
	fail "setting ${param##*/} did not taint the kernel"
if echo "$GC573_BDF" > "$drv/bind" 2> "$work/bind.err"; then
	echo 0 > "$param"
	fail "$mode: the bind succeeded"
fi
echo 0 > "$param"
echo "$mode: bind refused ($(sed 's/^.*: //' "$work/bind.err"))"
kmsg_since "$tag" | grep -E 'exp_|does not answer|does not read idle|not confirmed|bus mastering|kept until reboot|stopped before|FPGA version' |
	sed 's/^/  | /'

case $mode in
armed)
	kmsg_since "$tag" | grep -q 'exp_probe_armed: DMA_RUN 0x[0-9a-f]* read as 0x[0-9a-f]* (the audio DMA on)' ||
		fail "no exp_probe_armed line: the probe did not read DMA_RUN as armed"
	;;
ones)
	kmsg_since "$tag" | grep -q 'exp_mmio_ones 1: register reads return all-ones from now on' ||
		fail "no exp_mmio_ones line"
	;;
restop)
	# the stop counted as failed was confirmed first, or the case stops
	st=$(gc573_regs_idle "$regs") || {
		echo "!! BAR0 does not read idle ($st): the card's DMA may run. The card is left as it is; do not reboot or shut this machine down (spec/pci.md)"
		fail "the card does not read idle after the probe's stop ($st)"
	}
	kmsg_since "$tag" | grep -q 'exp_stop_fault 0x8: the probe stop was confirmed (DMA_RUN 0x[0-9a-f]* VIP_CTRL 0x[0-9a-f]*), counted as the audio DMA still on' ||
		fail "no line for the probe's stop confirmed, then counted as failed (a driver that does not read it back)"
	kmsg_since "$tag" | grep -q 'the stop of the engines at probe is not confirmed: DMA still on' ||
		fail "the probe did not take its stop as not confirmed"
	kmsg_since "$tag" | grep -q 'the stop of the engines at probe failed: bus mastering stays off, and the card gets no driver until reboot' ||
		fail "no line saying the card is dead with bus mastering off"
	kmsg_since "$tag" | grep -q ': 12 KiB of DMA memory kept until reboot' ||
		fail "no line saying 12 KiB are kept (the dummy list and the audio buffers)"
	;;
esac
if [ "$mode" != restop ]; then
	kmsg_since "$tag" | grep -q 'bus mastering was off when the probe started, and the card does not read idle' ||
		fail "the probe did not refuse the card for not reading idle with bus mastering off"
	kmsg_since "$tag" | grep -q 'stopped before bus mastering' &&
		fail "the probe stopped the engines of a card it must not write to"
	kmsg_since "$tag" | grep -q 'not idle at the probe.s start with bus mastering off: bus mastering stays off, and the card gets no driver until reboot' ||
		fail "no line saying the card is dead with bus mastering off"
	kmsg_since "$tag" | grep -q 'kept until reboot' && fail "memory kept, but the card was never given any"
fi
gc573_bound && fail "bound after the refused bind"
gc573_master_on && fail "bus mastering on: the probe turned it on"
gc573_dead_cards | grep -qx "$GC573_BDF" ||
	fail "dead_cards does not list $GC573_BDF: '$(gc573_dead_cards | tr '\n' ' ')'"
echo "dead: PCI enable count $(cat "$pdev/enable"), bus mastering off, in dead_cards"
if out=$(rmmod "$GC573_MOD" 2>&1); then
	fail "the module could be unloaded with a card dead"
fi
echo "rmmod refused: $out"
if echo "$GC573_BDF" > "$drv/bind" 2> "$work/bind.err"; then
	fail "the card could be bound again"
fi
echo "bind refused: $(sed 's/^.*: //' "$work/bind.err")"
gc573_master_on && fail "bus mastering on after the second bind"
gc573_sleep_test > "$work/sleep.out"
case $? in
0) fail "system sleep went through the freezer stage with a card dead" ;;
1) echo "system sleep refused: $(cat "$work/sleep.out")" ;;
*) echo "(no /sys/power/pm_test or no freeze state: sleep not tried)" ;;
esac
st=$(gc573_regs_idle "$regs") || fail "BAR0 does not read idle: $st"
echo "BAR0 (past the driver): $st"
echo "$mode: the card is dead until reboot, bus mastering never turned on"
