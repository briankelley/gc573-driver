#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# The probe's decision at its start (delta review D1, D10; final review
# F1). Bus mastering turned off under a running DMA and turned on again by
# the next probe stalled a CPU for some 15 s while the card read all-ones,
# and the next time it hung the host (spec/pci.md). The registers cannot
# tell such a cut from a clean unbind; only RESET's sticky done bits (3, 8
# and 9, 0x308) say whether a device reset came since a driver last
# brought the card up: 0x001 after one, 0x309 after a bring-up
# (spec/init.md step 2). So the driver never turns bus mastering off, an
# unbind included, and a probe that finds it off with those bits set, or
# with an engine on, writes no register and never turns it on: the card
# is dead until reboot. A card that reads all-ones is dead too. With bus
# mastering on, the probe stops the engines and reads the stop back. The
# probe logs its decision ("probe entry: ..."). The card itself is idle in
# every mode: only setpci (bus mastering off, on the idle card with no
# driver: harmless, spec/pci.md) and the parameters make the driver see it
# otherwise. One mode per run, GC573_TEST_ENTRY:
# - cut (default): an unbind, which must leave bus mastering on and the
#   PCI enable count at 1; setpci then turns bus mastering off (RESET
#   0x309), and a bind is refused for RESET's done bits;
# - ones: after the unbind, a bind with exp_mmio_ones 1 (every register
#   read all-ones from the probe's start): refused, bus mastering kept on;
# - restop (D10): after the unbind, a bind with exp_stop_fault bit 3: the
#   probe stops the engines and resets the domains, and the stop,
#   confirmed by DMA_RUN and VIP_CTRL read back idle, counts as the audio
#   DMA still on: refused, 12 KiB kept (the dummy list and the audio
#   buffers, which the stop gave the card), bus mastering kept on;
# - armed: the boot's first probe (RESET as after the VM's reset; SKIP
#   otherwise), with bus mastering turned off by setpci and the module
#   loaded with exp_probe_armed (the probe's read of DMA_RUN shows the
#   audio DMA on): refused for the engine;
# - fresh: the boot's first probe as in armed, with no parameter: the
#   probe takes the card (bus mastering off, RESET as after a device
#   reset, idle) and turns bus mastering on, a capture works, and the
#   unload leaves bus mastering on with the enable count at 1. Not dead.
# Setting a parameter must taint the kernel (module_param_unsafe). A
# refused card: the bind (or insmod's probe) fails with ENODEV; the entry
# line's verdict; cut, armed: the refusal's line, none for a stop of the
# engines, no memory kept, "bus mastering stays off" and bus mastering
# off; ones, restop: "the card keeps bus mastering" and bus mastering on;
# each: the card in dead_cards, the module not unloadable, no bind
# (ENODEV), runtime active with power/control at auto (D9c), INTx disabled
# (D14), system sleep refused (pm_test freezer), and BAR0, read past the
# driver, idle. run.sh runs this case last and skips the cases after it;
# after a refused mode the machine needs a reboot (in a VM:
# tools/vms/card-idle.sh first). Allowed: the failures this case provokes,
# and under DMA-API debug the report of the driver's DMA memory at the
# unwind.
# gc573-run: last
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

drv=/sys/bus/pci/drivers/$GC573_MOD
pdev=/sys/bus/pci/devices/$GC573_BDF
par=/sys/module/$GC573_MOD/parameters
mode=${GC573_TEST_ENTRY:-cut}
param= val=
case $mode in
cut | fresh) ;;
armed) param=$par/exp_probe_armed val=1 ;;
ones) param=$par/exp_mmio_ones val=1 ;;
restop) param=$par/exp_stop_fault val=8 ;;
*) fail "GC573_TEST_ENTRY: cut, ones, restop, armed or fresh, not '$mode'" ;;
esac
work=$(mktemp -d)
regs=$(gc573_regs_build "$work") || fail "cannot build gc573-regs"

cleanup() {
	[ -n "$param" ] && [ -w "$param" ] && echo 0 > "$param"
	[ -w /sys/power/pm_test ] && echo none > /sys/power/pm_test
	[ -n "$(gc573_dead_cards)" ] || { gc573_loaded && gc573_unload; }
	rm -rf "$work"
}
trap cleanup EXIT

{
	echo 'bus mastering was off when the probe started, and the card does not read idle'
	echo 'bus mastering was off when the probe started, and RESET 0x[0-9a-f]+ shows a bring-up since the card.s last reset'
	echo 'not idle at the probe.s start with bus mastering off: bus mastering stays off, and the card gets no driver until reboot'
	echo 'bus mastering off after a bring-up: bus mastering stays off, and the card gets no driver until reboot'
	echo 'the card does not answer \(VERSION ffffffff'
	echo 'the card does not answer at the probe.s start: the card keeps bus mastering and gets no driver until reboot'
	echo 'exp_probe_armed: DMA_RUN 0x[0-9a-f]+ read as'
	echo 'exp_stop_fault 0x[0-9a-f]+: the probe stop was confirmed'
	echo 'the stop of the engines at probe is not confirmed: DMA still on'
	echo 'the stop of the engines at probe failed: the card keeps bus mastering and gets no driver until reboot'
	echo 'system sleep refused: 1 card\(s\) did not confirm their DMA stopped'
	echo 'WARNING: CPU: [0-9]+ PID: [0-9]+ at kernel/dma/debug\.c:[0-9]+ dma_debug_device_change'
	echo 'DMA-API: Mapped at:'
} >> "$GC573_KMSG_ALLOW"

# RESET (0x00c), read past the driver
reset_reg() {
	"$regs" "$pdev/resource0" 0x00c | awk '$1 == "0x0000c" { print $2 }'
}

# Bus mastering off with setpci: only on the card with no driver, idle as
# BAR0 reads (spec/pci.md: harmless then); already off is left so
master_off() {
	local st
	gc573_bound && fail "the card is bound: bus mastering left as it is"
	st=$(gc573_regs_idle "$regs") ||
		fail "BAR0 does not read idle with no driver ($st): bus mastering left as it is"
	if ! gc573_master_on; then
		echo "bus mastering already off ($st)"
		return
	fi
	setpci -s "$GC573_BDF" COMMAND=0:4 || fail "setpci failed"
	gc573_master_on && fail "bus mastering still on after setpci"
	echo "bus mastering turned off by setpci, the card idle with no driver ($st)"
}

# The parameter was set and tainted the kernel (after tag $1)
tainted() {
	kmsg_since "$1" | grep -q "Setting dangerous option ${param##*/} - tainting kernel" ||
		fail "setting ${param##*/} did not taint the kernel"
}

bad=
if [ "$mode" = armed ] || [ "$mode" = fresh ]; then
	gc573_loaded && fail "$GC573_MOD is loaded: $mode needs the first probe of the boot"
	r=$(reset_reg)
	[ -n "$r" ] || fail "RESET cannot be read past the driver"
	[ $((r & 0x308)) = 0 ] ||
		skip "RESET $r: a driver brought the card up in this boot; reboot and run this mode first"
	echo "before the load: RESET $r (as after a device reset)"
	master_off
	tag=$(kmsg_mark "probe-entry $mode")
	if [ "$mode" = armed ]; then
		gc573_load exp_probe_armed=1 || fail "insmod failed"
		[ -w "$param" ] || fail "no ${param##*/} parameter (a driver without the check)"
		echo 0 > "$param"
		tainted "$tag"
	else
		gc573_load || fail "insmod failed"
	fi
	[ -e "$par/dead_cards" ] || fail "no dead_cards parameter"
else
	gc573_load || fail "insmod failed"
	[ -z "$param" ] || [ -w "$param" ] || fail "no ${param##*/} parameter (a driver without the check)"
	[ -e "$par/dead_cards" ] || fail "no dead_cards parameter"
	[ -z "$(gc573_dead_cards)" ] || fail "a card is dead already: reboot first"
	gc573_bound || fail "$GC573_BDF not bound after the load"
	echo "$GC573_BDF" > "$drv/unbind" || fail "unbind failed"
	# F1: a clean unbind leaves bus mastering on, enabled once
	x=$(cat "$pdev/enable")
	gc573_master_on || bad+="bus mastering off after a clean unbind (the driver turned it off); "
	[ "$x" = 1 ] || bad+="PCI enable count $x after the unbind, not 1; "
	st=$(gc573_regs_idle "$regs") || fail "BAR0 does not read idle after the unbind: $st"
	echo "unbound: bus mastering $(gc573_master_on && echo on || echo off), PCI enable count $x, BAR0 $st, RESET $(reset_reg)"
	[ "$mode" != cut ] || master_off
	tag=$(kmsg_mark "probe-entry $mode")
	if [ -n "$param" ]; then
		echo "$val" > "$param" || fail "cannot set ${param##*/}"
		tainted "$tag"
	fi
	brc=0
	echo "$GC573_BDF" > "$drv/bind" 2> "$work/bind.err" || brc=$?
	[ -z "$param" ] || echo 0 > "$param"
	if [ $brc = 0 ]; then
		kmsg_since "$tag" | grep "$GC573_MOD" | head -20 | sed 's/^/  | /'
		fail "${bad}$mode: the bind succeeded"
	fi
	echo "$mode: bind refused ($(sed 's/^.*: //' "$work/bind.err"))"
fi
kmsg_since "$tag" | grep -E 'probe entry|exp_|does not answer|does not read idle|bring-up|not confirmed|bus mastering|kept until reboot|stopped before|FPGA version' |
	sed 's/^/  | /'
[ -z "$bad" ] || fail "${bad%; }"

# The probe's entry line, with bus mastering $1 and a verdict matching $2
entry() {
	kmsg_since "$tag" | grep -qE ": probe entry: bus mastering $1, RESET 0x[0-9a-f]{8}, GPIO 0x[0-9a-f]{8}, VERSION [0-9a-f]{8}, DMA_RUN 0x[0-9a-f]{8}, VIP_CTRL 0x[0-9a-f]{8}: $2" ||
		fail "no probe entry line with bus mastering $1 and the verdict '$2'"
}

if [ "$mode" = fresh ]; then
	entry off 'brought up: bus mastering off, RESET as after a device reset, idle'
	gc573_bound || fail "fresh: the card was not bound"
	gc573_master_on || fail "fresh: bus mastering off after the probe"
	cap=$(gc573_cap_build "$work") || fail "cannot build gc573-cap"
	vdev=$(gc573_video_dev) || fail "no video device"
	gc573_input_off "$vdev"
	"$cap" -d "$vdev" -n 10 > "$work/cap.log" 2>&1 ||
		{ cat "$work/cap.log"; fail "fresh: a capture failed"; }
	echo "fresh: bound, bus mastering on, capture: $(tail -1 "$work/cap.log")"
	gc573_unload || fail "rmmod failed"
	x=$(cat "$pdev/enable")
	gc573_master_on || fail "fresh: bus mastering off after the unload (the driver turned it off)"
	[ "$x" = 1 ] || fail "fresh: PCI enable count $x after the unload, not 1"
	echo "fresh: unloaded, bus mastering on, PCI enable count $x"
	exit 0
fi

gc573_bound && fail "bound after the refused probe"
case $mode in
cut)
	entry off 'dead until reboot, nothing written: bus mastering off after a bring-up'
	kmsg_since "$tag" | grep -q 'bus mastering was off when the probe started, and RESET 0x[0-9a-f]* shows a bring-up since the card.s last reset' ||
		fail "the probe did not refuse the card for RESET's done bits with bus mastering off"
	kmsg_since "$tag" | grep -q 'bus mastering off after a bring-up: bus mastering stays off, and the card gets no driver until reboot' ||
		fail "no line saying the card is dead with bus mastering off"
	;;
armed)
	entry off 'dead until reboot, nothing written: bus mastering off and not idle'
	kmsg_since "$tag" | grep -q 'exp_probe_armed: DMA_RUN 0x[0-9a-f]* read as 0x[0-9a-f]* (the audio DMA on)' ||
		fail "no exp_probe_armed line: the probe did not read DMA_RUN as armed"
	kmsg_since "$tag" | grep -q 'bus mastering was off when the probe started, and the card does not read idle' ||
		fail "the probe did not refuse the card for not reading idle with bus mastering off"
	kmsg_since "$tag" | grep -q 'not idle at the probe.s start with bus mastering off: bus mastering stays off, and the card gets no driver until reboot' ||
		fail "no line saying the card is dead with bus mastering off"
	;;
ones)
	entry on 'dead until reboot, nothing written: the card does not answer'
	kmsg_since "$tag" | grep -q 'exp_mmio_ones 1: register reads return all-ones from now on' ||
		fail "no exp_mmio_ones line"
	kmsg_since "$tag" | grep -q ': the card does not answer (VERSION ffffffff .*): its DMA may run; nothing is written to the card$' ||
		fail "no line for the card not answering at the probe's start"
	kmsg_since "$tag" | grep -q 'the card does not answer at the probe.s start: the card keeps bus mastering and gets no driver until reboot' ||
		fail "no line saying the card is dead with bus mastering on"
	;;
restop)
	entry on 'the engines are stopped and checked'
	# the stop counted as failed was confirmed first, or the case stops
	st=$(gc573_regs_idle "$regs") || {
		echo "!! BAR0 does not read idle ($st): the card's DMA may run. The card is left as it is; do not reboot or shut this machine down (spec/pci.md)"
		fail "the card does not read idle after the probe's stop ($st)"
	}
	kmsg_since "$tag" | grep -q 'exp_stop_fault 0x8: the probe stop was confirmed (DMA_RUN 0x[0-9a-f]* VIP_CTRL 0x[0-9a-f]*), counted as the audio DMA still on' ||
		fail "no line for the probe's stop confirmed, then counted as failed (a driver that does not read it back)"
	kmsg_since "$tag" | grep -q 'the stop of the engines at probe is not confirmed: DMA still on' ||
		fail "the probe did not take its stop as not confirmed"
	kmsg_since "$tag" | grep -q 'the stop of the engines at probe failed: the card keeps bus mastering and gets no driver until reboot' ||
		fail "no line saying the card is dead with bus mastering on"
	kmsg_since "$tag" | grep -q ': 12 KiB of DMA memory kept until reboot' ||
		fail "no line saying 12 KiB are kept (the dummy list and the audio buffers)"
	;;
esac
if [ "$mode" != restop ]; then
	kmsg_since "$tag" | grep -q 'stopped before bus mastering' &&
		fail "the probe stopped the engines of a card it must not write to"
	kmsg_since "$tag" | grep -q 'FPGA version' &&
		fail "the probe went on to the FPGA init"
	kmsg_since "$tag" | grep -q 'kept until reboot' && fail "memory kept, but the card was never given any"
fi
case $mode in
cut | armed) gc573_master_on && fail "bus mastering on: the probe turned it on" ;;
*) gc573_master_on || fail "bus mastering off: the driver turned it off" ;;
esac
gc573_dead_cards | grep -qx "$GC573_BDF" ||
	fail "dead_cards does not list $GC573_BDF: '$(gc573_dead_cards | tr '\n' ' ')'"
echo "dead: PCI enable count $(cat "$pdev/enable"), bus mastering $(gc573_master_on && echo on || echo off), in dead_cards"
if out=$(rmmod "$GC573_MOD" 2>&1); then
	fail "the module could be unloaded with a card dead"
fi
echo "rmmod refused: $out"
m0=$(gc573_master_on && echo on || echo off)
if echo "$GC573_BDF" > "$drv/bind" 2> "$work/bind.err"; then
	fail "the card could be bound again"
fi
echo "bind refused: $(sed 's/^.*: //' "$work/bind.err")"
m1=$(gc573_master_on && echo on || echo off)
[ "$m0" = "$m1" ] || fail "bus mastering $m0 before the second bind, $m1 after"
gc573_dead_left
gc573_sleep_test > "$work/sleep.out"
case $? in
0) fail "system sleep went through the freezer stage with a card dead" ;;
1) echo "system sleep refused: $(cat "$work/sleep.out")" ;;
*) echo "(no /sys/power/pm_test or no freeze state: sleep not tried)" ;;
esac
st=$(gc573_regs_idle "$regs") || fail "BAR0 does not read idle: $st"
echo "BAR0 (past the driver): $st"
echo "$mode: the card is dead until reboot, bus mastering $m1 as the probe found it"
