#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# A card that stops answering with bus mastering on (fix review N2), with
# the test parameter exp_mmio_ones (tests/cases/26-no-answer.sh has the
# modes that leave the card usable). The card itself is idle: no stream
# ever starts, and the parameter only makes the driver's register reads
# return all-ones. One mode per run, GC573_TEST_NOANSWER:
# 3 (default) for 25 s once bus mastering is on: the probe gives up after
#   20 s.
# 4 from the probe's check after bus mastering on, for good: the FPGA init
#   stops at an all-ones read (DDR_STATUS), and the unwind's stop cannot be
#   confirmed.
# Either way the card is dead until reboot: -ENODEV, the memory the card
# was given kept (the dummy list and the audio buffers, 12 KiB), bus
# mastering still on and the device still enabled, the card in
# dead_cards, the module held, no bind (ENODEV: no driver matches it);
# and BAR0, read past the driver, idle. run.sh runs this case last and
# skips the cases after it; the machine needs a reboot after it (in a VM:
# tools/vms/card-idle.sh first). Allowed: the failures this case
# provokes, and under DMA-API debug the report of the kept memory at the
# unwind.
# gc573-run: last
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

param=/sys/module/$GC573_MOD/parameters/exp_mmio_ones
drv=/sys/bus/pci/drivers/$GC573_MOD
pdev=/sys/bus/pci/devices/$GC573_BDF
mode=${GC573_TEST_NOANSWER:-3}
case $mode in 3 | 4) ;; *) fail "GC573_TEST_NOANSWER: 3 or 4, not '$mode'" ;; esac
work=$(mktemp -d)
regs=$(gc573_regs_build "$work") || fail "cannot build gc573-regs"

cleanup() {
	[ -w "$param" ] && echo 0 > "$param"
	[ -n "$(gc573_dead_cards)" ] || { gc573_loaded && gc573_unload; }
	rm -rf "$work"
}
trap cleanup EXIT

{
	echo 'since bus mastering went on \([0-9a-f]+ before\): the card is not ready; waiting up to 20 s'
	echo 'the card stopped answering after bus mastering was enabled: the card keeps bus mastering and gets no driver until reboot'
	echo 'video stop \(no INT bit 0, no reset of domain 0\) failed: the card keeps bus mastering and gets no driver until reboot'
	echo 'teardown stop failed: the card does not answer'
	echo 'WARNING: CPU: [0-9]+ PID: [0-9]+ at kernel/dma/debug\.c:[0-9]+ dma_debug_device_change'
	echo 'DMA-API: Mapped at:'
} >> "$GC573_KMSG_ALLOW"

gc573_load || fail "insmod failed"
[ -w "$param" ] || fail "no exp_mmio_ones parameter (a driver without the checks)"
[ -e "/sys/module/$GC573_MOD/parameters/dead_cards" ] || fail "no dead_cards parameter"
[ -z "$(gc573_dead_cards)" ] || fail "a card is dead already: reboot first"
echo "$GC573_BDF" > "$drv/unbind" || fail "unbind failed"
tag=$(kmsg_mark "no-answer $mode")
echo "$mode" > "$param" || fail "cannot set exp_mmio_ones $mode"
kmsg_since "$tag" | grep -q 'Setting dangerous option exp_mmio_ones - tainting kernel' ||
	fail "setting exp_mmio_ones did not taint the kernel"
t0=$(date +%s)
if echo "$GC573_BDF" > "$drv/bind" 2> "$work/bind.err"; then
	fail "mode $mode: the bind succeeded"
fi
echo 0 > "$param"
echo "mode $mode: bind refused ($(sed 's/^.*: //' "$work/bind.err")) after $(($(date +%s) - t0)) s"
kmsg_since "$tag" | grep -E 'exp_mmio_ones|does not answer|bus mastering|answers again|kept until reboot|FPGA version' |
	sed 's/^/  | /'
case $mode in
3)
	kmsg_since "$tag" | grep -q 'the card stopped answering after bus mastering was enabled: the card keeps bus mastering and gets no driver until reboot' ||
		fail "no 'stopped answering' line"
	;;
4)
	kmsg_since "$tag" | grep -q 'DDR check: the card does not answer' ||
		fail "the FPGA init did not stop at the DDR check"
	kmsg_since "$tag" | grep -q 'failed: the card keeps bus mastering and gets no driver until reboot' ||
		fail "the unwind's stop was not taken as failed"
	;;
esac
kmsg_since "$tag" | grep -q ': 12 KiB of DMA memory kept until reboot' ||
	fail "no line saying 12 KiB are kept (the dummy list and the audio buffers)"
st=$(gc573_regs_idle "$regs") || fail "BAR0 does not read idle: $st"
echo "BAR0 (past the driver): $st"
gc573_master_on || fail "bus mastering off: the driver turned it off"
x=$(cat "$pdev/enable")
[ "$x" -ge 1 ] || fail "the device was disabled at the unwind (bus mastering went off with it)"
gc573_dead_cards | grep -qx "$GC573_BDF" ||
	fail "dead_cards does not list $GC573_BDF: '$(gc573_dead_cards | tr '\n' ' ')'"
echo "dead: PCI enable count $x, bus mastering on, in dead_cards"
if out=$(rmmod "$GC573_MOD" 2>&1); then
	fail "the module could be unloaded with a card dead"
fi
echo "rmmod refused: $out"
if echo "$GC573_BDF" > "$drv/bind" 2> "$work/bind.err"; then
	fail "the card could be bound again"
fi
echo "bind refused: $(sed 's/^.*: //' "$work/bind.err")"
echo "mode $mode left the card as it is until reboot: bus mastering on, the memory it was given kept"
