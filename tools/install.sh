#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Install the GC573 (AVerMedia Live Gamer 4K) driver with DKMS.
#
# Builds and installs gc573.ko for the running kernel; DKMS builds it again
# for every kernel installed later (dkms.conf AUTOINSTALL), as long as that
# kernel's headers are installed too. The module then loads by itself
# whenever the card is present (its PCI ID, 1461:0054, is in the module's
# alias list).
#
# A reboot is the way back from any trouble, so a crash while gc573 takes
# the card must never repeat at boot. gc573 loads by itself only once it
# has taken the card on this system: until then, and while a driverctl
# override keeps the card for another driver, a modprobe.d entry
# (/etc/modprobe.d/gc573-no-autoload.conf) keeps it from loading by its
# alias. "modprobe gc573" and driverctl still load it.
#
# A persistent driverctl override that gives the card to another driver
# (vfio-pci, to pass it to a virtual machine) leaves three choices:
#   --this-boot  gc573 takes the card for this boot only (driverctl
#                --nosave). The override stays saved, and a reboot gives
#                the card back. The default when you answer on a terminal.
#   --permanent  remove the override, so gc573 takes the card at every
#                boot. Asks first; --yes skips that (needed without a
#                terminal).
#   --no-bind    install only and leave the card alone.
# Without a terminal and without one of these, the card is left alone. A
# virtual machine that is using the card stops the script before it
# touches the card.
#
# An update while an older gc573 has the card takes the card from it
# (unbind), unloads it and loads the new one. PipeWire, which keeps the
# card's ALSA control node open on a desktop, lets go of it by itself.
# Any other program with the card open (OBS, a capture) would lose the
# card: the script names it and leaves the card alone, unless --yes.
#
# Other ways of reserving the card (vfio-pci.ids on the kernel command
# line or in modprobe.d) are reported, not changed.
#
# Usage: sudo tools/install.sh [--this-boot | --permanent | --no-bind] [--yes]
#   --yes: no question for --permanent, and programs that have the card
#   open lose it at an update
# Undo:  sudo tools/uninstall.sh [--yes]
set -euo pipefail

NAME=gc573
PCI_ID=1461:0054
STATE_DIR=/var/lib/gc573-install
STATE=$STATE_DIR/state
NOLOAD=/etc/modprobe.d/gc573-no-autoload.conf

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

mode= yes=0
for a in "$@"; do
	case $a in
	--this-boot) m=this-boot ;;
	--permanent) m=permanent ;;
	--no-bind) m=no-bind ;;
	--yes|-y) yes=1; continue ;;
	-h|--help) sed -n '3,/^set -euo/{/^set -euo/d; s/^# \{0,1\}//; p}' "$0"; exit 0 ;;
	*) die "unknown option $a (see --help)" ;;
	esac
	[ -z "$mode" ] || [ "$mode" = "$m" ] || die "--$mode and --$m exclude each other"
	mode=$m
done
tty=0
[ -t 0 ] && [ -t 1 ] && tty=1
[ "$mode" != permanent ] || [ "$yes" = 1 ] || [ "$tty" = 1 ] ||
	die "--permanent removes the driverctl override for good: without a terminal to ask on, add --yes"

[ "$(id -u)" = 0 ] || exec sudo -- "$0" "$@"

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tools/card-release.sh
. "$root/tools/card-release.sh"
for f in dkms.conf Makefile Kbuild; do
	[ -f "$root/$f" ] || die "$root/$f is missing: run the script from a complete source tree"
done
ver=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$root/dkms.conf")
[ -n "$ver" ] || die "no PACKAGE_VERSION in $root/dkms.conf"
krel=$(uname -r)

# distribution family, for package names in the hints (in a subshell:
# os-release sets NAME, VERSION and more)
ids=$(. /etc/os-release 2>/dev/null; echo " ${ID:-} ${ID_LIKE:-} ")
case $ids in
*" debian "*|*" ubuntu "*) fam=deb ;;
*" fedora "*|*" rhel "*|*" centos "*) fam=rpm ;;
*) fam=other ;;
esac

# ---- prerequisites ----
if ! command -v dkms > /dev/null; then
	case $fam in
	deb) die "dkms is not installed. Install it with: sudo apt install dkms" ;;
	rpm) die "dkms is not installed. Install it with: sudo dnf install dkms (RHEL, AlmaLinux, Rocky: enable EPEL first: sudo dnf install epel-release)" ;;
	*) die "dkms is not installed: install your distribution's dkms package" ;;
	esac
fi
if [ ! -f "/lib/modules/$krel/build/Makefile" ]; then
	case $fam in
	deb) hint="sudo apt install linux-headers-$krel" ;;
	rpm) hint="sudo dnf install kernel-devel-$krel" ;;
	*) hint="install the headers package for kernel $krel" ;;
	esac
	die "no headers for the running kernel $krel (/lib/modules/$krel/build). Install them with: $hint, then run this again"
fi
for t in make gcc; do
	command -v "$t" > /dev/null ||
		die "$t is not installed (needed to build kernel modules): install your distribution's build tools (deb: build-essential; rpm: gcc make)"
done

# ---- build and install with DKMS ----
# Earlier versions (or an earlier copy of this one) go first
if [ -d "/var/lib/dkms/$NAME" ]; then
	for d in /var/lib/dkms/$NAME/*/; do
		old=$(basename "$d")
		case $old in kernel-*) continue ;; esac
		say "removing the installed $NAME $old from DKMS"
		dkms remove -m "$NAME" -v "$old" --all > /dev/null 2>&1 || true
		rm -rf "/usr/src/$NAME-$old"
	done
fi
src=/usr/src/$NAME-$ver
rm -rf "$src"
mkdir -p "$src/src"
cp "$root/dkms.conf" "$root/Makefile" "$root/Kbuild" "$src/"
cp "$root"/src/*.[ch] "$src/src/"
say "building $NAME $ver for $krel with DKMS (this takes a minute)"
dkms add -m "$NAME" -v "$ver" > /dev/null || die "dkms add failed"
if ! out=$(dkms build -m "$NAME" -v "$ver" -k "$krel" 2>&1); then
	printf '%s\n' "$out" | tail -20 >&2
	log=/var/lib/dkms/$NAME/$ver/build/make.log
	[ -f "$log" ] && { say "--- $log (last 30 lines) ---" >&2; tail -30 "$log" >&2; }
	dkms remove -m "$NAME" -v "$ver" --all > /dev/null 2>&1 || true
	rm -rf "$src"
	die "the build failed (log above); nothing was installed"
fi
dkms install -m "$NAME" -v "$ver" -k "$krel" > /dev/null || die "dkms install failed"
say "installed: $(modinfo -n "$NAME" 2>/dev/null)"

# the other installed kernels that have headers, so a fallback kernel has
# the driver too
for b in /lib/modules/*/build; do
	k=$(basename "$(dirname "$b")")
	{ [ "$k" != "$krel" ] && [ -f "$b/Makefile" ]; } || continue
	if dkms build -m "$NAME" -v "$ver" -k "$k" > /dev/null 2>&1 &&
	   dkms install -m "$NAME" -v "$ver" -k "$k" > /dev/null 2>&1; then
		say "also installed for kernel $k"
	else
		say "note: the build for kernel $k failed, so that kernel has no $NAME (the running kernel has)"
	fi
done

# future kernels: DKMS needs their headers
case $fam in
deb)
	# a headers metapackage (linux-headers-generic, -virtual, -generic-hwe-..)
	# brings the headers of each new kernel
	dpkg-query -W -f='${Package} ${Status}\n' 'linux-headers-*' 2>/dev/null |
		awk '$1 !~ /^linux-headers-[0-9]/ && / installed$/ { f = 1 } END { exit !f }' ||
		say "note: no linux-headers metapackage is installed, so kernel updates may come without headers and DKMS cannot rebuild the module for them. To keep it working across updates: sudo apt install linux-headers-generic (or the variant that matches your kernel package)" ;;
rpm)
	rpm -q kernel-devel > /dev/null 2>&1 ||
		say "note: kernel-devel is not installed as a package, so kernel updates may come without headers and DKMS cannot rebuild the module for them: sudo dnf install kernel-devel" ;;
esac

# ---- Secure Boot ----
sb=off
if command -v mokutil > /dev/null && mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
	sb=on
fi

# ---- the card ----
dev=
for d in /sys/bus/pci/devices/*; do
	[ "$(cat "$d/vendor")" = 0x${PCI_ID%%:*} ] && [ "$(cat "$d/device")" = 0x${PCI_ID##*:} ] &&
		{ dev=$d; break; }
done
if [ -z "$dev" ]; then
	say "no GC573 card found: the driver loads by itself once the card is present"
	exit 0
fi
bdf=$(basename "$dev")
drv=
[ -e "$dev/driver" ] && drv=$(basename "$(readlink -f "$dev/driver")")
ovr=$(cat "$dev/driver_override" 2>/dev/null || true)
[ "$ovr" = "(null)" ] && ovr=
say "card: $bdf, driver now: ${drv:-none}${ovr:+, driver_override: $ovr}"

if grep -qi "vfio-pci.ids=[^ ]*$PCI_ID" /proc/cmdline; then
	say "warning: the kernel command line reserves the card for vfio-pci (vfio-pci.ids=...$PCI_ID). Remove $PCI_ID from it in your boot loader configuration (e.g. GRUB_CMDLINE_LINUX in /etc/default/grub, then update-grub) to use the card with $NAME"
fi
if grep -qsi "ids=[^ ]*$PCI_ID" /etc/modprobe.d/*.conf; then
	say "warning: a file in /etc/modprobe.d gives vfio-pci the card ($(grep -lsi "ids=[^ ]*$PCI_ID" /etc/modprobe.d/*.conf | tr '\n' ' ')). Remove $PCI_ID there (and rebuild the initramfs) to use the card with $NAME"
fi

# driverctl keeps a persistent override in /etc/driverctl.d/pci-<device>,
# holding the driver's name (its list-overrides shows the driver bound now)
persistent=
if command -v driverctl > /dev/null && [ -f "/etc/driverctl.d/pci-$bdf" ]; then
	persistent=$(cat "/etc/driverctl.d/pci-$bdf")
fi
# A virtual machine using the card through vfio-pci holds its group device
# open; taking the card from under it would stall it or the unbind
user=
if [ "$drv" = vfio-pci ] && [ -e "$dev/iommu_group" ]; then
	grp=/dev/vfio/$(basename "$(readlink -f "$dev/iommu_group")")
	for fd in /proc/[0-9]*/fd/*; do
		[ "$(readlink "$fd" 2>/dev/null)" = "$grp" ] || continue
		p=${fd#/proc/}; p=${p%%/*}
		vmname=$(tr '\0' ' ' < "/proc/$p/cmdline" | grep -o 'guest=[^, ]*' | head -1 || true)
		user="process $p ($(cat "/proc/$p/comm" 2>/dev/null))${vmname:+, virtual machine ${vmname#guest=}}"
		break
	done
fi
vm_busy() {
	[ -n "$user" ] || return 1
	say "the card is in use by a virtual machine through vfio-pci: $user. Shut that virtual machine down (or move the card out of it), then run this again; the card was not touched"
}

bound() { if [ -L "$dev/driver" ]; then basename "$(readlink "$dev/driver")"; fi; }

# gc573 kept from loading by its alias (so at boot); $1: why
noload_on() {
	[ -f "$NOLOAD" ] && return 0
	cat > "$NOLOAD" <<- EOF
	# Written by the gc573 driver's tools/install.sh: gc573 does not load by
	# itself (by its PCI alias), so it does not take the card at boot ($1).
	# "modprobe gc573" and driverctl still load it. install.sh removes this
	# file once gc573 is to take the card at every boot; uninstall.sh too.
	blacklist $NAME
	EOF
}
noload_off() { rm -f "$NOLOAD"; }

# Load the new module. An older copy loaded without the card (a failed
# probe, or the card elsewhere) goes first, so that the new one is what
# takes it
load_module() {
	local out key
	if [ -d "/sys/module/$NAME" ] && [ "$(bound)" != "$NAME" ]; then
		gc573_unload_wait ||
			say "warning: an older $NAME is loaded and cannot be unloaded; it is the one that takes the card until a reboot"
	fi
	if ! out=$(modprobe "$NAME" 2>&1); then
		say "modprobe $NAME failed: $out"
		if [ "$sb" = on ]; then
			key=
			for k in /var/lib/shim-signed/mok/MOK.der /var/lib/dkms/mok.pub; do [ -f "$k" ] && { key=$k; break; }; done
			say "Secure Boot is on, and the kernel loads only modules signed with an enrolled key. Enroll the key DKMS signs with: sudo mokutil --import ${key:-<the DKMS signing key>}, reboot, and confirm the key in the blue MOK manager screen"
		fi
		return 1
	fi
}

# Wait for gc573 on the card and its nodes (udev and the driver need a
# moment), then name them
card_up() {
	local v a
	for _ in $(seq 50); do
		[ -e "/sys/bus/pci/drivers/$NAME/$bdf" ] && [ -n "$(ls "$dev"/video4linux 2>/dev/null)" ] && break
		sleep 0.1
	done
	[ -e "/sys/bus/pci/drivers/$NAME/$bdf" ] || return 1
	v=$(ls "$dev/video4linux" 2>/dev/null | head -1)
	a=$(cat "$dev"/sound/card*/id 2>/dev/null | head -1)
	say "the card is up: video /dev/${v:-?}, ALSA card ${a:-?}"
}

record() { mkdir -p "$STATE_DIR"; printf 'bind %s %s %s\n' "$1" "$bdf" "$persistent" > "$STATE"; }

if [ -n "$persistent" ] && [ "$persistent" != "$NAME" ]; then
	say ""
	say "A persistent driverctl override gives the card ($bdf) to $persistent."
	say "This is how the card is passed to a virtual machine (VFIO)."
	if [ -z "$mode" ] && [ "$tty" = 1 ]; then
		say "  1) $NAME takes the card for this boot only. The override stays saved,"
		say "     and a reboot gives the card back to $persistent."
		say "  2) $NAME takes the card for good: the override is removed."
		say "  3) Leave the card alone for now."
		read -r -p "Choose 1, 2 or 3 [1]: " ans || ans=3
		case $ans in
		""|1) mode=this-boot ;;
		2) mode=permanent ;;
		*) mode=no-bind ;;
		esac
	elif [ -z "$mode" ]; then
		say "(no terminal, and none of --this-boot, --permanent or --no-bind given: the card is left alone)"
		mode=no-bind
	fi
	case $mode in
	no-bind)
		noload_on "a driverctl override keeps the card for $persistent"
		say "the card stays with $persistent. $NAME is installed, and does not load by itself while the override is saved. To use the card with $NAME:"
		say "  for this boot (a reboot undoes it): sudo tools/install.sh --this-boot"
		say "  for good: sudo tools/install.sh --permanent"
		exit 0
		;;
	this-boot)
		! vm_busy || exit 1
		noload_on "a driverctl override keeps the card for $persistent"
		record this-boot
		# an older gc573 with the card already (an earlier --this-boot):
		# it lets go of the card (PipeWire by itself; another program only
		# with --yes) and the new one takes over
		if [ "$drv" = "$NAME" ] && ! gc573_release "$yes"; then
			say "the older $NAME keeps the card. Run this again once the card is free, or reboot (the card goes back to $persistent) and run this again"
			exit 1
		fi
		load_module || exit 1
		# --nosave: driver_override for this boot; the saved override is
		# untouched. Judged by the result, not driverctl's exit status
		driverctl --nosave set-override "$bdf" "$NAME" > /dev/null 2>&1 || true
		if ! card_up; then
			say "warning: $NAME did not take the card; see: sudo dmesg | grep $NAME. A reboot gives the card back to $persistent"
			exit 1
		fi
		say "$NAME has the card for this boot. A reboot gives it back to $persistent: the override stays saved."
		say "To switch for good: sudo tools/install.sh --permanent. uninstall.sh gives the card back at once."
		exit 0
		;;
	permanent)
		! vm_busy || exit 1
		if [ "$yes" != 1 ]; then
			say "$NAME will then take the card at every boot. If it ever hangs the system while starting, boot once with module_blacklist=$NAME on the kernel command line (in GRUB: press e and add it to the line that starts with linux), then run uninstall.sh."
			read -r -p "Remove the override for good? [y/N] " ans || ans=n
			case $ans in
			y|Y|yes|YES) ;;
			*)
				noload_on "a driverctl override keeps the card for $persistent"
				say "nothing changed: the card stays with $persistent (sudo tools/install.sh --this-boot to try $NAME until the next reboot)"
				exit 0 ;;
			esac
		fi
		# recorded first: a crash at the first probe must not lose the
		# override for uninstall.sh. Autoload stays off until that probe
		# has worked
		record permanent
		noload_on "until $NAME has taken the card once"
		# --noprobe: without it driverctl stops with an error, before it
		# deletes the persistent override, when no driver takes the card at
		# once (gc573 binds below)
		driverctl --noprobe unset-override "$bdf" > /dev/null 2>&1 || true
		ovr=$(cat "$dev/driver_override" 2>/dev/null || true)
		[ "$ovr" = "(null)" ] && ovr=
		if [ -f "/etc/driverctl.d/pci-$bdf" ] || [ -n "$ovr" ]; then
			die "driverctl unset-override $bdf failed; the override may still be in place (driverctl list-persisted)"
		fi
		say "override removed. To give the card back to $persistent (and virtual machines): sudo driverctl set-override $bdf $persistent"
		say "uninstall.sh offers to put it back."
		drv=$(bound)
		;;
	esac
elif [ -n "$ovr" ] && [ "$ovr" != "$NAME" ]; then
	say "warning: the card's driver_override is '$ovr' (set by hand or a script, not by driverctl): $NAME cannot bind until it is cleared: echo > $dev/driver_override as root, or reboot"
	exit 0
elif [ "$mode" = no-bind ]; then
	say "the card is left alone (--no-bind). $NAME loads by itself at the next boot, or now with: sudo modprobe $NAME"
	exit 0
elif [ -n "$mode" ]; then
	say "note: no driverctl override holds the card, so --$mode changes nothing: installing as usual"
fi

# bind: no override (any more). An older gc573 with the card lets go of
# it (PipeWire by itself; another program only with --yes) and is reloaded
if [ "$drv" = "$NAME" ]; then
	if gc573_release "$yes"; then
		say "reloading $NAME"
	else
		say "the older $NAME keeps the card: the new one takes over after a reboot, or when this runs again with the card free"
		noload_off
		exit 1
	fi
elif [ -n "$drv" ]; then
	say "warning: the card is bound to $drv, not $NAME. Unbind it (echo $bdf > /sys/bus/pci/drivers/$drv/unbind as root) or remove that driver, then: sudo modprobe $NAME"
	exit 0
fi
# the first probe on this system with autoload off: if it brings the
# system down, the next boot does not try again
noload_on "until $NAME has taken the card once"
if ! load_module || ! card_up; then
	[ -d "/sys/module/$NAME" ] && say "warning: $NAME loaded but did not bind $bdf; see: sudo dmesg | grep $NAME"
	say "$NAME does not load by itself until it has taken the card once: run this script again after fixing that ($NOLOAD)"
	exit 1
fi
noload_off
say "$NAME loads by itself from now on whenever the card is present"
