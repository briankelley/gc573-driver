#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Test tools/install.sh and tools/uninstall.sh at a git ref in gc573-dev,
# which holds the card (the matrix VMs have none: install-test.sh). Run on
# the host; everything it changes is inside gc573-dev, apart from the test
# pattern on the loopback output (tools/testsrc/show.sh, as tests/live.sh).
#   prepare        the development module unloaded (OBS stopped), no gc573
#                  in DKMS; driverctl installed and an override that binds
#                  the card to vfio-pci, as on a host that passes the card
#                  to a virtual machine (in the VM vfio-pci cannot take it,
#                  there is no IOMMU: the card sits unbound, overridden;
#                  driverctl --noprobe, or driverctl would not save it)
#   install-notty  install.sh without a terminal: gc573 built and installed
#                  with DKMS, the override left in place (not asked), and
#                  the commands to remove it and to put it back printed
#   install-no     with a terminal, answer n: the same
#   install-yes    answer y: the override gone, gc573 bound, the video and
#                  ALSA devices up, the removed override recorded
#   reboot         after a reboot gc573 is loaded (PCI modalias) and bound;
#                  with the pattern on the loopback output the input locks
#                  at 1920x1080 and 30 frames stream
#   uninstall      uninstall.sh with a terminal, answer y (put the override
#                  back): gc573 unloaded, nothing left in DKMS, under
#                  /lib/modules or in /usr/src, the override back
#   cleanup        the override removed and driverctl purged, as before the
#                  test; reboot (then tools/vmbuild.sh load for development)
# Log: tests/logs/install/<UTC>-<sha>/gc573-dev-card.log (+ summary.tsv)
# Usage: tools/vms/install-card-test.sh [-r REF]
set -uo pipefail

REF=HEAD VM=gc573-dev
while [ $# -gt 0 ]; do
	case $1 in
	-r) REF=$2; shift 2 ;;
	-h|--help) sed -n '3,30p' "$0"; exit 0 ;;
	*) echo "unknown argument $1" >&2; exit 2 ;;
	esac
done
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
sha=$(git -C "$root" rev-parse --short=12 "$REF^{commit}")
out=$root/tests/logs/install/$(date -u +%Y%m%dT%H%M%SZ)-$sha
mkdir -p "$out"
log=$out/$VM-card.log
export DISPLAY=${DISPLAY:-:0} XAUTHORITY=${XAUTHORITY:-$HOME/.Xauthority}
OUTPUT=${GC573_OUTPUT:-DVI-D-0}
ALIAS=pci:v00001461d00000054sv00001461sd00005730bc04sc00i00

vm() { ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$VM" "$@"; }
# with a terminal, $1 typed as the answer
vm_tty() { printf '%s\n' "$1" | ssh -tt -o BatchMode=yes "$VM" "$2" | tr -d '\r'; }
res() { printf 'RESULT\t%s\t%s\t%s\n' "$1" "$2" "$3"; }
wait_boot() {	# $1: boot id before
	local i
	for i in $(seq 90); do
		sleep 2
		b=$(vm cat /proc/sys/kernel/random/boot_id 2>/dev/null) || continue
		[ "$b" != "$1" ] && return 0
	done
	return 1
}
state() {	# driver bound, override, DKMS
	vm "d=/sys/bus/pci/devices/$bdf; echo \"driver: \$([ -L \$d/driver ] && basename \$(readlink \$d/driver)) override: \$(cat \$d/driver_override) persisted: \$(cat /etc/driverctl.d/pci-$bdf 2>/dev/null) dkms: \$(dkms status gc573 2>/dev/null | tr '\n' ' ') video: \$(ls \$d/video4linux 2>/dev/null | tr '\n' ' ') alsa: \$(cat \$d/sound/card*/id 2>/dev/null)\""
}

{
echo "# install.sh / uninstall.sh with the card, $VM"
echo "date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')  ref: $REF ($sha)"
echo "vm: $(vm '. /etc/os-release; echo "$PRETTY_NAME, kernel $(uname -r)"')"
bdf=$(vm "lspci -D -d 1461:0054 | cut -d' ' -f1")
echo "card: $bdf"
[ -n "$bdf" ] || { echo "no card in $VM"; exit 2; }

echo "=== prepare"
vm "pkill -x obs; sleep 2; sudo rmmod gc573 2>/dev/null; true"
git -C "$root" archive --prefix=gc573/ "$REF" | ssh -o BatchMode=yes "$VM" 'rm -rf ~/gc573-install && mkdir -p ~/gc573-install && tar -x -C ~/gc573-install'
vm "cd ~/gc573-install/gc573 && sudo bash tools/uninstall.sh" | sed 's/^/  /'
vm "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q driverctl" | tail -1
vm "sudo driverctl --noprobe set-override $bdf vfio-pci" 2>&1 | sed 's/^/  /'
s=$(state); echo "  $s"
if grep -q 'override: vfio-pci persisted: vfio-pci' <<< "$s" && ! grep -q 'driver: gc573' <<< "$s"; then
	res prepare PASS "override $bdf -> vfio-pci, card not bound to gc573"
else
	res prepare FAIL "$s"
fi

echo "=== install-notty"
o=$(vm "cd ~/gc573-install/gc573 && sudo bash tools/install.sh" 2>&1); rc=$?
echo "$o" | sed 's/^/  /'
s=$(state); echo "  $s"
if [ $rc = 0 ] && grep -q 'not asking: no terminal' <<< "$o" &&
	grep -q "driverctl unset-override $bdf" <<< "$o" &&
	grep -q "driverctl set-override $bdf vfio-pci" <<< "$o" &&
	grep -q 'persisted: vfio-pci' <<< "$s" && grep -q 'dkms: gc573/' <<< "$s" &&
	! grep -q 'driver: gc573' <<< "$s"; then
	res install-notty PASS "exit 0; installed ($(grep -o 'dkms: [^,]*, [^,]*' <<< "$s")); override left, removal and restore commands printed"
else
	res install-notty FAIL "exit $rc; $s"
fi

echo "=== install-no"
o=$(vm_tty n "cd ~/gc573-install/gc573 && sudo bash tools/install.sh"); rc=$?
echo "$o" | sed 's/^/  /'
s=$(state); echo "  $s"
if [ $rc = 0 ] && grep -q 'Remove the override now' <<< "$o" && grep -q 'override left in place' <<< "$o" &&
	grep -q 'persisted: vfio-pci' <<< "$s" && ! grep -q 'driver: gc573' <<< "$s"; then
	res install-no PASS "asked; n: override left in place, card not bound"
else
	res install-no FAIL "exit $rc; $s"
fi

echo "=== install-yes"
o=$(vm_tty y "cd ~/gc573-install/gc573 && sudo bash tools/install.sh"); rc=$?
echo "$o" | sed 's/^/  /'
s=$(state); echo "  $s"
st=$(vm "sudo cat /var/lib/gc573-install/state 2>/dev/null")
if [ $rc = 0 ] && grep -q 'override removed' <<< "$o" && grep -q 'the card is up' <<< "$o" &&
	grep -q 'driver: gc573' <<< "$s" && grep -q 'override: (null) persisted:  dkms' <<< "$s" &&
	grep -q 'video: video' <<< "$s" && grep -q 'alsa: GC573' <<< "$s" &&
	[ "$st" = "override $bdf vfio-pci" ]; then
	res install-yes PASS "y: override removed and recorded ($st); $(grep -o 'the card is up: .*' <<< "$o")"
else
	res install-yes FAIL "exit $rc; state '$st'; $s"
fi

echo "=== reboot"
b0=$(vm cat /proc/sys/kernel/random/boot_id)
vm "sudo systemctl reboot" 2>/dev/null
if wait_boot "$b0"; then
	sleep 5
	s=$(state); echo "  $s"
	"$root/tools/testsrc/show.sh" "$OUTPUT" 1920x1080 60 > /dev/null 2>&1 ||
		{ sleep 5; "$root/tools/testsrc/show.sh" "$OUTPUT" 1920x1080 60 > /dev/null 2>&1; }
	q=none
	for _ in $(seq 30); do
		q=$(vm "v4l2-ctl -d /dev/\$(ls /sys/bus/pci/devices/$bdf/video4linux | head -1) --query-dv-timings 2>/dev/null | grep -E 'Active (width|height)' | awk '{ print \$3 }' | paste -sd x") && [ -n "$q" ] && break
		sleep 1
	done
	c=$(vm "v4l2-ctl -d /dev/\$(ls /sys/bus/pci/devices/$bdf/video4linux | head -1) --set-dv-bt-timings query --stream-mmap --stream-count 30 2>&1 | tail -1; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' ')
	"$root/tools/testsrc/show.sh" --off > /dev/null 2>&1
	echo "  lock: $q; capture: $c"
	if grep -q 'driver: gc573' <<< "$s" && grep -q 'video: video' <<< "$s" &&
		grep -q 'alsa: GC573' <<< "$s" && [ "$q" = 1920x1080 ] && grep -q 'rc=0' <<< "$c"; then
		res reboot PASS "gc573 loaded by its alias and bound after the boot; input locked at $q; 30 frames streamed"
	else
		res reboot FAIL "lock '$q'; capture '$c'; $s"
	fi
else
	res reboot FAIL "no new boot within 3 min"
fi

echo "=== uninstall"
o=$(vm_tty y "cd ~/gc573-install/gc573 && sudo bash tools/uninstall.sh"); rc=$?
echo "$o" | sed 's/^/  /'
s=$(state); echo "  $s"
left=$(vm "sudo dkms status 2>/dev/null | grep gc573; find /lib/modules /usr/src -name 'gc573*' 2>/dev/null; modprobe -n -v $ALIAS 2>/dev/null | grep gc573; lsmod | grep -w gc573" | tr '\n' ' ')
if [ $rc = 0 ] && grep -q "override restored: $bdf -> vfio-pci" <<< "$o" &&
	grep -q 'override: vfio-pci persisted: vfio-pci' <<< "$s" && [ -z "$left" ] && ! grep -q 'driver: gc573' <<< "$s"; then
	res uninstall PASS "unloaded, nothing left in DKMS, /lib/modules, /usr/src; override back: $bdf -> vfio-pci"
else
	res uninstall FAIL "exit $rc; left '$left'; $s"
fi

echo "=== cleanup"
vm "sudo driverctl --noprobe unset-override $bdf; sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y -q driverctl | tail -1; rm -rf ~/gc573-install"
b0=$(vm cat /proc/sys/kernel/random/boot_id)
vm "sudo systemctl reboot" 2>/dev/null
wait_boot "$b0" && sleep 5
s=$(state); echo "  $s"
if grep -q 'override: (null) persisted:  dkms' <<< "$s" &&
	! vm "dpkg -s driverctl > /dev/null 2>&1"; then
	res cleanup PASS "no override, driverctl purged, rebooted"
else
	res cleanup FAIL "$s"
fi
} 2>&1 | tee "$log"
grep -P '^RESULT\t' "$log" | sed "s/^RESULT\t/$VM\t/" > "$out/summary.tsv"
column -t -s $'\t' "$out/summary.tsv"
echo "log: ${log#"$root"/}"
