#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M0: probe binds the card, uses MSI and logs the FPGA VERSION register; remove
# quiesces (INT_ENABLE reads 0) and unbinds. Loads with dynamic debug on, so the
# log keeps the init and quiesce register readbacks.
# M2: probe registers a V4L2 capture node under the PCI device, with the
# driver's debugfs state file next to it.
# Fix review N7: setting a stop test parameter (exp_stop_fault,
# exp_stop_domains) taints the kernel, here with their defaults (no
# effect); so does exp_probe_armed (delta review D1).
# MSI only by default (exp_intx 0; INTx is untested on the card and storms
# its line under VFIO, spec/open-questions.md #43): with MSI disallowed for
# the device (sysfs msi_bus 0, which the PCI core reads at the next MSI
# request), the probe refuses the card with its "MSI unavailable" line and
# requests no IRQ, INTx included; with msi_bus 1 again it binds with MSI.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

par=/sys/module/$GC573_MOD/parameters
tag=$(kmsg_mark probe)
gc573_load dyndbg=+p || fail "insmod failed"
if ! gc573_bound; then
	gc573_unload
	fail "$GC573_BDF not bound"
fi
dev=$(gc573_video_dev)
dbg=$(cat "$(gc573_debugfs)" 2>/dev/null)
ttag=$(kmsg_mark "probe: test parameters")
echo 0 > "$par/exp_stop_fault" && echo -1 > "$par/exp_stop_domains" &&
	echo 0 > "$par/exp_probe_armed"
rc=$?
taint=$(kmsg_since "$ttag" | grep -c 'Setting dangerous option \(exp_stop_fault\|exp_stop_domains\|exp_probe_armed\) - tainting kernel')
gc573_unload || fail "rmmod failed"
[ $rc = 0 ] || fail "cannot write exp_stop_fault, exp_stop_domains and exp_probe_armed"
[ "$taint" = 3 ] || fail "setting exp_stop_fault, exp_stop_domains and exp_probe_armed tainted the kernel $taint times, not 3"
echo "exp_stop_fault, exp_stop_domains, exp_probe_armed: setting each taints the kernel"

[ -n "$dev" ] || fail "no video4linux node under $GC573_BDF"
echo "video node: $dev"
echo "$dbg" | grep -q '^stream: running 0 ' || fail "debugfs video state missing"
echo "debugfs: $(gc573_debugfs)"
echo "$dbg" | grep -E '^(core|input):' | sed 's/^/  /'
gc573_bound && fail "$GC573_BDF still bound after rmmod"

log=$(kmsg_since "$tag")
ver=$(echo "$log" | sed -n 's/.*: FPGA version \([0-9a-f]\{8\}\)$/\1/p')
[ -n "$ver" ] || fail "no FPGA version line"
echo "FPGA version $ver (spec/regmap.md: 20200811)"

echo "$log" | grep -q ': using MSI, irq ' || fail "not using MSI"
echo "MSI in use"

if echo "$log" | grep -q ': state at probe: '; then
	echo "$log" | grep -q ': quiesced: INT_ENABLE=0x00000000 ' ||
		fail "quiesce readback missing or INT_ENABLE != 0"
	echo "quiesce: INT_ENABLE reads 0 after remove"
else
	echo "no dynamic debug output: quiesce readback not checked"
fi

# MSI disallowed: no bind, no IRQ, and the reason in the log
msi_bus=/sys/bus/pci/devices/$GC573_BDF/msi_bus
want="MSI unavailable: INTx is untested on this card (exp_intx=1 allows it)"
echo "$GC573_MOD [^ ]+: error -[A-Z0-9]+: MSI unavailable: INTx is untested on this card \\(exp_intx=1 allows it\\)\$" \
	>> "${GC573_KMSG_ALLOW:-/dev/null}"
trap 'echo 1 > "$msi_bus" 2>/dev/null' EXIT
mtag=$(kmsg_mark "probe: MSI disallowed")
echo 0 > "$msi_bus" || fail "cannot disallow MSI for $GC573_BDF ($msi_bus)"
gc573_load || fail "insmod with MSI disallowed failed"
bound=0
gc573_bound && bound=1
irqs=$(grep -cw "$GC573_MOD" /proc/interrupts)
gc573_unload || fail "rmmod failed"
echo 1 > "$msi_bus" || fail "cannot allow MSI again ($msi_bus)"
trap - EXIT
mlog=$(kmsg_since "$mtag")
[ "$bound" = 0 ] || fail "bound with MSI disallowed"
[ "$irqs" = 0 ] || fail "with MSI disallowed: $irqs gc573 IRQs in /proc/interrupts"
grep -q ": using INTx" <<< "$mlog" && fail "took INTx with MSI disallowed"
grep -qF ": $want" <<< "$mlog" || fail "with MSI disallowed: no line \"$want\""
echo "MSI disallowed: not bound, no IRQ: $(grep -oF -- "$want" <<< "$mlog" | head -1)"
mtag=$(kmsg_mark "probe: MSI allowed again")
gc573_load || fail "insmod failed"
gc573_bound || { gc573_unload; fail "not bound with MSI allowed again"; }
gc573_unload || fail "rmmod failed"
kmsg_since "$mtag" | grep -q ': using MSI, irq ' || fail "not using MSI with MSI allowed again"
echo "MSI allowed again: binds with MSI"
