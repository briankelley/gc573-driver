#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Test tools/install.sh and tools/uninstall.sh at a git ref in gc573-dev,
# which holds the card (the matrix VMs have none: install-test.sh). Run on
# the host; everything it changes is inside gc573-dev, apart from the test
# pattern on the loopback output (tools/testsrc/show.sh, as tests/live.sh).
# A persistent driverctl override to vfio-pci plays a host that passes the
# card to a virtual machine. In the VM vfio-pci cannot take the card (no
# IOMMU), so the card then sits unbound and overridden.
#   prepare            development module unloaded (OBS stopped), no gc573
#                      in DKMS; driverctl installed, the override saved
#                      (driverctl --noprobe, or it would not save it)
#   install-notty      no terminal, no option: installed with DKMS, the card
#                      left alone, gc573 kept from loading by alias
#   permanent-refused  --permanent without a terminal and --yes: refused
#                      before anything is done
#   install-3          terminal, choice 3: the card left alone
#   boot-race          why the modprobe.d entry: without it, a reboot has
#                      gc573 probe the card before driverctl's unit applies
#                      the saved override (the entry is put back after)
#   install-1          terminal, the default choice (1): gc573 has the card
#                      for this boot, the override still saved
#   reboot-this-boot   after a reboot gc573 is not even loaded (no probe at
#                      boot) and the saved override holds the card again
#   install-this-boot  --this-boot without a terminal: gc573 has the card;
#                      the input locks at 1920x1080 and 30 frames stream
#   uninstall-this-boot  the saved override loaded again, nothing left
#   install-permanent  --permanent --yes: the override removed and recorded,
#                      gc573 has the card, loads by alias from now on
#   reboot-permanent   after a reboot gc573 loaded by alias and bound; the
#                      input locks, 30 frames stream
#   uninstall-permanent  terminal, Enter (yes): the override back as it was,
#                      nothing left in DKMS, /lib/modules or /usr/src
#   no-override        without any override: install.sh takes the card at
#                      once and lets gc573 load by alias only after that
#                      first probe worked; uninstall.sh --yes leaves nothing
#   cleanup            driverctl purged, as before the test; reboot (then
#                      tools/vmbuild.sh load for development)
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
state() {	# driver bound, override, loaded, autoload off, install state, DKMS
	vm "d=/sys/bus/pci/devices/$bdf; echo \"driver: \$([ -L \$d/driver ] && basename \$(readlink \$d/driver)) override: \$(cat \$d/driver_override) persisted: \$(cat /etc/driverctl.d/pci-$bdf 2>/dev/null) loaded: \$([ -d /sys/module/gc573 ] && echo yes || echo no) noload: \$([ -f /etc/modprobe.d/gc573-no-autoload.conf ] && echo yes || echo no) state: \$(sudo cat /var/lib/gc573-install/state 2>/dev/null) dkms: \$(dkms status gc573 2>/dev/null | tr '\n' ' ') video: \$(ls \$d/video4linux 2>/dev/null | tr '\n' ' ') alsa: \$(cat \$d/sound/card*/id 2>/dev/null)\""
}
has() { grep -q -- "$1" <<< "$2"; }
# the input locked at 1920x1080 and 30 frames streamed (show.sh's pattern)
stream_check() {
	"$root/tools/testsrc/show.sh" "$OUTPUT" 1920x1080 60 > /dev/null 2>&1 ||
		{ sleep 5; "$root/tools/testsrc/show.sh" "$OUTPUT" 1920x1080 60 > /dev/null 2>&1; }
	q=none
	for _ in $(seq 30); do
		# until locked: while the source settles, the query can fail with
		# ENOLCK, and v4l2-ctl then prints the zeroed timings (0x0)
		q=$(vm "v4l2-ctl -d /dev/\$(ls /sys/bus/pci/devices/$bdf/video4linux | head -1) --query-dv-timings 2>/dev/null | grep -E 'Active (width|height)' | awk '{ print \$3 }' | paste -sd x")
		[ "$q" = 1920x1080 ] && break
		sleep 1
	done
	c=$(vm "v4l2-ctl -d /dev/\$(ls /sys/bus/pci/devices/$bdf/video4linux | head -1) --set-dv-bt-timings query --stream-mmap --stream-count 30 2>&1 | tail -1; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' ')
	"$root/tools/testsrc/show.sh" --off > /dev/null 2>&1
	echo "  lock: $q; capture: $c"
	[ "$q" = 1920x1080 ] && has 'rc=0' "$c"
}
reboot_vm() {
	local b0
	b0=$(vm cat /proc/sys/kernel/random/boot_id)
	vm "sudo systemctl reboot" 2>/dev/null
	wait_boot "$b0" && sleep 5
}
I="cd ~/gc573-install/gc573 && sudo bash tools/install.sh"
U="cd ~/gc573-install/gc573 && sudo bash tools/uninstall.sh"

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
vm "$U --yes" | sed 's/^/  /'
vm "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q driverctl" | tail -1
vm "sudo driverctl --noprobe set-override $bdf vfio-pci" 2>&1 | sed 's/^/  /'
s=$(state); echo "  $s"
if has 'override: vfio-pci persisted: vfio-pci' "$s" && ! has 'driver: gc573' "$s" && has 'noload: no state:  dkms' "$s"; then
	res prepare PASS "override $bdf -> vfio-pci saved, card not bound to gc573, nothing installed"
else
	res prepare FAIL "$s"
fi

echo "=== install-notty"
o=$(vm "$I" 2>&1); rc=$?
echo "$o" | sed 's/^/  /'
s=$(state); echo "  $s"
if [ $rc = 0 ] && has 'no terminal, and none of' "$o" && has 'install.sh --this-boot' "$o" &&
	has 'install.sh --permanent' "$o" && has 'persisted: vfio-pci' "$s" && has 'dkms: gc573/' "$s" &&
	has 'loaded: no noload: yes' "$s" && ! has 'driver: gc573' "$s"; then
	res install-notty PASS "exit 0; installed ($(grep -o 'dkms: [^,]*, [^,]*' <<< "$s")); the card left alone, gc573 not loaded, autoload off; the options printed"
else
	res install-notty FAIL "exit $rc; $s"
fi

echo "=== permanent-refused"
t0=$(date +%s)
o=$(vm "$I --permanent" 2>&1); rc=$?
echo "$o" | sed 's/^/  /'
s=$(state); echo "  $s"
if [ $rc = 1 ] && has 'add --yes' "$o" && ! has 'building' "$o" && has 'persisted: vfio-pci' "$s"; then
	res permanent-refused PASS "exit 1 in $(( $(date +%s) - t0 )) s, before the build; the override still saved"
else
	res permanent-refused FAIL "exit $rc; $s"
fi

echo "=== install-3"
o=$(vm_tty 3 "$I"); rc=$?
echo "$o" | sed 's/^/  /'
s=$(state); echo "  $s"
if [ $rc = 0 ] && has 'Choose 1, 2 or 3' "$o" && has 'the card stays with vfio-pci' "$o" &&
	has 'persisted: vfio-pci' "$s" && has 'noload: yes' "$s" && ! has 'driver: gc573' "$s"; then
	res install-3 PASS "asked; 3: the card left alone, autoload off"
else
	res install-3 FAIL "exit $rc; $s"
fi

echo "=== boot-race"
# why the modprobe.d entry: without it, does gc573 take the card at boot
# before driverctl's unit gives it to the saved override's driver?
vm "sudo mv /etc/modprobe.d/gc573-no-autoload.conf /var/tmp/gc573-no-autoload.conf"
if reboot_vm; then
	s=$(state); echo "  $s"
	k=$(vm "sudo dmesg | grep -E '\\] gc573 [0-9a-f]{4}:' | head -3")
	echo "$k" | sed 's/^/  /'
	vm "systemctl --no-pager status 'driverctl@*' 2>&1 | grep -E 'Active|load-override' | head -3" | sed 's/^/  /'
	if [ -n "$k" ] && has 'override: vfio-pci persisted: vfio-pci' "$s"; then
		res boot-race PASS "without the entry gc573 probed the card at boot ($(head -1 <<< "$k" | cut -c1-80)); driverctl's unit then set the saved override"
	else
		res boot-race FAIL "no gc573 probe at boot without the entry, or the override not applied; $s"
	fi
else
	res boot-race FAIL "no new boot within 3 min"
fi
vm "sudo mv /var/tmp/gc573-no-autoload.conf /etc/modprobe.d/gc573-no-autoload.conf"

echo "=== install-1"
o=$(vm_tty '' "$I"); rc=$?
echo "$o" | sed 's/^/  /'
s=$(state); echo "  $s"
if [ $rc = 0 ] && has 'has the card for this boot' "$o" && has 'driver: gc573 override: gc573 persisted: vfio-pci' "$s" &&
	has "noload: yes state: bind this-boot $bdf vfio-pci" "$s" && has 'video: video' "$s" && has 'alsa: GC573' "$s"; then
	res install-1 PASS "asked; Enter (1): gc573 has the card for this boot, the override still saved, recorded; $(grep -o 'the card is up: .*' <<< "$o")"
else
	res install-1 FAIL "exit $rc; $s"
fi

echo "=== reboot-this-boot"
if reboot_vm; then
	s=$(state); echo "  $s"
	# the driver's own lines ("gc573 0000:07:00.0: ...", "gc573: ..."), not
	# the VM's host name
	k=$(vm "sudo dmesg | grep -cE '\\] gc573[: ]'")
	echo "  kernel log lines from gc573 since the boot: $k"
	if has 'driver:  override: vfio-pci persisted: vfio-pci loaded: no noload: yes' "$s" && [ "$k" = 0 ]; then
		res reboot-this-boot PASS "after the reboot gc573 is not loaded and never probed (no kernel log line); the saved override holds the card (driver_override vfio-pci)"
	else
		res reboot-this-boot FAIL "kernel log lines $k; $s"
	fi
else
	res reboot-this-boot FAIL "no new boot within 3 min"
fi

echo "=== install-this-boot"
o=$(vm "$I --this-boot" 2>&1); rc=$?
echo "$o" | sed 's/^/  /'
s=$(state); echo "  $s"
if [ $rc = 0 ] && has 'driver: gc573 override: gc573 persisted: vfio-pci' "$s" && stream_check; then
	res install-this-boot PASS "no terminal, --this-boot: gc573 has the card; input locked at $q; 30 frames streamed"
else
	res install-this-boot FAIL "exit $rc; lock '$q'; capture '$c'; $s"
fi

echo "=== uninstall-this-boot"
o=$(vm "$U" 2>&1); rc=$?
echo "$o" | sed 's/^/  /'
s=$(state); echo "  $s"
left=$(vm "sudo dkms status 2>/dev/null | grep gc573; find /lib/modules /usr/src -name 'gc573*' 2>/dev/null; modprobe -n -v $ALIAS 2>/dev/null | grep gc573" | tr '\n' ' ')
if [ $rc = 0 ] && has "the saved override is loaded again: $bdf -> vfio-pci" "$o" &&
	has 'driver:  override: vfio-pci persisted: vfio-pci loaded: no noload: no state:  dkms' "$s" && [ -z "$left" ]; then
	res uninstall-this-boot PASS "no terminal: the saved override loaded again (driver_override vfio-pci), gc573 unloaded, nothing left"
else
	res uninstall-this-boot FAIL "exit $rc; left '$left'; $s"
fi

echo "=== install-permanent"
o=$(vm "$I --permanent --yes" 2>&1); rc=$?
echo "$o" | sed 's/^/  /'
s=$(state); echo "  $s"
if [ $rc = 0 ] && has 'override removed' "$o" && has 'loads by itself from now on' "$o" &&
	has "driver: gc573 override: (null) persisted:  loaded: yes noload: no state: bind permanent $bdf vfio-pci" "$s"; then
	res install-permanent PASS "--permanent --yes: the override removed and recorded, gc573 has the card, autoload on after the first probe"
else
	res install-permanent FAIL "exit $rc; $s"
fi

echo "=== reboot-permanent"
if reboot_vm; then
	s=$(state); echo "  $s"
	if has 'driver: gc573' "$s" && has 'video: video' "$s" && has 'alsa: GC573' "$s" && stream_check; then
		res reboot-permanent PASS "gc573 loaded by its alias and bound after the boot; input locked at $q; 30 frames streamed"
	else
		res reboot-permanent FAIL "lock '$q'; capture '$c'; $s"
	fi
else
	res reboot-permanent FAIL "no new boot within 3 min"
fi

echo "=== uninstall-permanent"
o=$(vm_tty '' "$U"); rc=$?
echo "$o" | sed 's/^/  /'
s=$(state); echo "  $s"
left=$(vm "sudo dkms status 2>/dev/null | grep gc573; find /lib/modules /usr/src -name 'gc573*' 2>/dev/null; modprobe -n -v $ALIAS 2>/dev/null | grep gc573; lsmod | grep -w gc573" | tr '\n' ' ')
if [ $rc = 0 ] && has "override restored: $bdf -> vfio-pci" "$o" &&
	has 'driver:  override: vfio-pci persisted: vfio-pci loaded: no noload: no state:  dkms' "$s" && [ -z "$left" ]; then
	res uninstall-permanent PASS "asked; Enter (yes): the override back as it was, gc573 unloaded, nothing left in DKMS, /lib/modules, /usr/src"
else
	res uninstall-permanent FAIL "exit $rc; left '$left'; $s"
fi

echo "=== no-override"
vm "sudo driverctl --noprobe unset-override $bdf" 2>&1 | sed 's/^/  /'
o=$(vm "$I" 2>&1); rc=$?
echo "$o" | sed 's/^/  /'
s=$(state); echo "  $s"
o2=$(vm "$U --yes" 2>&1); rc2=$?
echo "$o2" | sed 's/^/  /'
s2=$(state); echo "  $s2"
left=$(vm "sudo dkms status 2>/dev/null | grep gc573; find /lib/modules /usr/src -name 'gc573*' 2>/dev/null; lsmod | grep -w gc573" | tr '\n' ' ')
if [ $rc = 0 ] && ! has 'A persistent driverctl override' "$o" && has 'loads by itself from now on' "$o" &&
	has 'driver: gc573 override: (null) persisted:  loaded: yes noload: no state:  dkms: gc573/' "$s" &&
	[ $rc2 = 0 ] && has 'driver:  override: (null) persisted:  loaded: no noload: no state:  dkms' "$s2" && [ -z "$left" ]; then
	res no-override PASS "no override: gc573 took the card at once, autoload on after that first probe; uninstall --yes left nothing"
else
	res no-override FAIL "exit $rc/$rc2; left '$left'; $s / $s2"
fi

echo "=== cleanup"
vm "sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y -q driverctl | tail -1; rm -rf ~/gc573-install"
reboot_vm
s=$(state); echo "  $s"
if has 'override: (null) persisted:  loaded: no noload: no state:  dkms' "$s" &&
	! vm "dpkg -s driverctl > /dev/null 2>&1"; then
	res cleanup PASS "no override, driverctl purged, rebooted"
else
	res cleanup FAIL "$s"
fi
} 2>&1 | tee "$log"
grep -P '^RESULT\t' "$log" | sed "s/^RESULT\t/$VM\t/" > "$out/summary.tsv"
column -t -s $'\t' "$out/summary.tsv"
echo "log: ${log#"$root"/}"
