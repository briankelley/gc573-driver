#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# May the VM that holds the GC573 be shut down or rebooted, or lose the
# card to a live detach, now? Each of them turns the card's bus mastering
# off (QEMU's VFIO reset at a reboot, vfio-pci's release at a shutdown or
# a detach), and that must never happen while the card's DMA may run: it
# can hang the host (spec/pci.md). Run it before any of them; a VM that
# holds the card is shut down, never destroyed.
# Usage: tools/vms/card-idle.sh VM      (ssh alias = VM name)
# Safe (exit 0):
# - no GC573 in the VM, or its bus mastering is off;
# - gc573 has the card and has not left it dead: its teardown, shutdown
#   and remove stop the DMA, confirmed, before bus mastering goes off;
# - gc573 left the card dead (its dead_cards), but only by a test's
#   parameter (the kernel log: exp_stop_fault after a confirmed stop, or
#   exp_mmio_ones), and BAR0 reads idle;
# - no driver has the card, or another one does: BAR0 reads idle twice,
#   100 ms apart.
# BAR0 idle: VIP_CTRL output enable (bit 0) and DMA_RUN audio (bit 1) off,
# neither all-ones, read past any driver (tests/gc573-regs.c, built in the
# VM with its gcc). Anything else (exit 1, the reason on stderr): leave
# the VM running. A card whose stop really failed has no safe way out of
# a VM (README.md, Known limitations). Exit 2: usage.
set -euo pipefail

[ $# = 1 ] && [ -n "$1" ] || { echo "usage: $0 VM" >&2; exit 2; }
VM=$1
here=$(cd "$(dirname "$0")" && pwd)
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$VM")

"${SSH[@]}" 'cat > /tmp/gc573-card-idle-regs.c' < "$here/../../tests/gc573-regs.c" ||
	{ echo "card-idle: $VM: no ssh" >&2; exit 1; }
"${SSH[@]}" sudo bash -s <<'EOS'
set -uo pipefail
src=/tmp/gc573-card-idle-regs.c
d=""
for f in /sys/bus/pci/devices/*; do
	if [ "$(cat "$f/vendor")" = 0x1461 ] && [ "$(cat "$f/device")" = 0x0054 ]; then
		d=$f
		break
	fi
done
[ -n "$d" ] || { rm -f "$src"; echo "card-idle: no GC573 in this VM: safe"; exit 0; }
bdf=${d##*/}
no() { rm -f "$src"; echo "card-idle: $bdf: $*: do not shut down, reboot or detach (spec/pci.md)" >&2; exit 1; }
ok() { rm -f "$src"; echo "card-idle: $bdf: $*: safe"; exit 0; }

cmd=$(od -An -tx2 -j4 -N2 "$d/config" | tr -d ' ')
[ -n "$cmd" ] && [ "$cmd" != ffff ] || no "its config space does not answer ($cmd)"
[ $((0x$cmd & 4)) != 0 ] || ok "bus mastering off (PCI_COMMAND $cmd)"
drv=""
[ -L "$d/driver" ] && drv=$(basename "$(readlink "$d/driver")")
dead=$(grep -x "$bdf" /sys/module/gc573/parameters/dead_cards 2>/dev/null || true)
[ "$drv" = gc573 ] && [ -z "$dead" ] &&
	ok "gc573 has it: its shutdown, teardown and remove stop the DMA, confirmed, before bus mastering goes off"
if [ -n "$dead" ]; then
	klog=$({ journalctl -k -b -o cat --no-pager 2>/dev/null; dmesg; } | grep -F "gc573 $bdf: ")
	grep -qE 'exp_stop_fault 0x[0-9a-f]+: the (video|teardown|probe|audio) stop was confirmed|exp_mmio_ones [0-9]+: register reads return all-ones' <<< "$klog" ||
		no "gc573 left it dead (a stop it could not confirm), and no test parameter did that: its DMA may still run"
	why="gc573 left it dead by a test parameter (kernel log), and BAR0 reads idle"
else
	why="${drv:-no driver} has it, and BAR0 reads idle twice"
fi
gcc -O2 -o /tmp/gc573-card-idle-regs "$src" 2> /dev/null ||
	no "cannot build the register reader (gcc)"
rm -f "$src"
idle() {
	local out run vip
	out=$(/tmp/gc573-card-idle-regs "$d/resource0" 0x008 0x1000 2>&1) ||
		{ echo "BAR0 cannot be read: $out"; return 1; }
	run=$(awk '$1 == "0x00008" { print $2 }' <<< "$out")
	vip=$(awk '$1 == "0x01000" { print $2 }' <<< "$out")
	echo "DMA_RUN $run VIP_CTRL $vip"
	[ -n "$run" ] && [ -n "$vip" ] && [ "$run" != 0xffffffff ] &&
		[ "$vip" != 0xffffffff ] && [ $((run & 2)) = 0 ] && [ $((vip & 1)) = 0 ]
}
s1=$(idle) || { rm -f /tmp/gc573-card-idle-regs; no "bus mastering on, ${drv:-no driver}, $s1"; }
sleep 0.1
s2=$(idle) || { rm -f /tmp/gc573-card-idle-regs; no "bus mastering on, ${drv:-no driver}, $s2"; }
rm -f /tmp/gc573-card-idle-regs
ok "$why ($s2)"
EOS
