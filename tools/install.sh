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
# Before that it checks for root, dkms and the running kernel's headers,
# and looks at what holds the card now. A driverctl override that binds the
# card to another driver (vfio-pci, for passing it to a virtual machine) is
# removed only if you answer yes on a terminal; the script prints how to put
# it back, and uninstall.sh offers to. Other ways of reserving the card
# (vfio-pci.ids on the kernel command line or in modprobe.d) are reported,
# not changed.
#
# Usage: sudo tools/install.sh
# Undo:  sudo tools/uninstall.sh
set -euo pipefail

NAME=gc573
PCI_ID=1461:0054
STATE_DIR=/var/lib/gc573-install
STATE=$STATE_DIR/state

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || exec sudo -- "$0" "$@"

root=$(cd "$(dirname "$0")/.." && pwd)
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

persistent=
if command -v driverctl > /dev/null && driverctl list-overrides 2>/dev/null | grep -q "^$bdf "; then
	persistent=$(driverctl list-overrides | awk -v b="$bdf" '$1 == b { print $2 }')
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
if [ -n "$user" ]; then
	say "the card is in use by a virtual machine through vfio-pci: $user. Shut that virtual machine down (or move the card out of it), then run this again; nothing about the card was changed"
	exit 1
fi

if [ -n "$persistent" ] && [ "$persistent" != "$NAME" ]; then
	say ""
	say "A persistent driverctl override binds the card ($bdf) to $persistent."
	say "This is how the card is given to a virtual machine (VFIO passthrough)."
	say "While it stays, $NAME cannot use the card on this system."
	ans=n
	if [ -t 0 ] && [ -t 1 ]; then
		read -r -p "Remove the override now, so that $NAME drives the card? [y/N] " ans || ans=n
	else
		say "(not asking: no terminal)"
	fi
	case $ans in
	y|Y|yes|YES)
		driverctl unset-override "$bdf" || die "driverctl unset-override $bdf failed; the override may still be in place (driverctl list-overrides)"
		mkdir -p "$STATE_DIR"
		printf 'override %s %s\n' "$bdf" "$persistent" > "$STATE"
		say "override removed. To give the card back to $persistent (and virtual machines): sudo driverctl set-override $bdf $persistent"
		say "uninstall.sh offers to put it back."
		ovr= drv=
		[ -e "$dev/driver" ] && drv=$(basename "$(readlink -f "$dev/driver")")
		;;
	*)
		say "override left in place. To use the card with $NAME later: sudo driverctl unset-override $bdf (to put it back: sudo driverctl set-override $bdf $persistent)"
		exit 0
		;;
	esac
elif [ -n "$ovr" ] && [ "$ovr" != "$NAME" ]; then
	say "warning: the card's driver_override is '$ovr' (set by hand or a script, not by driverctl): $NAME cannot bind until it is cleared: echo > $dev/driver_override as root, or reboot"
	exit 0
fi

# bind: load the new module (reload an older one if it is not in use)
if [ "$drv" = "$NAME" ]; then
	if modprobe -r "$NAME" 2>/dev/null; then
		say "reloading $NAME"
	else
		say "an older $NAME is loaded and in use: the new one takes over after a reboot (or close the applications using the card and run: sudo modprobe -r $NAME && sudo modprobe $NAME)"
		exit 0
	fi
elif [ -n "$drv" ]; then
	say "warning: the card is bound to $drv, not $NAME. Unbind it (echo $bdf > /sys/bus/pci/drivers/$drv/unbind as root) or remove that driver, then: sudo modprobe $NAME"
	exit 0
fi
if ! out=$(modprobe "$NAME" 2>&1); then
	say "modprobe $NAME failed: $out"
	if [ "$sb" = on ]; then
		key=
		for k in /var/lib/shim-signed/mok/MOK.der /var/lib/dkms/mok.pub; do [ -f "$k" ] && { key=$k; break; }; done
		say "Secure Boot is on, and the kernel loads only modules signed with an enrolled key. Enroll the key DKMS signs with: sudo mokutil --import ${key:-<the DKMS signing key>}, reboot, and confirm the key in the blue MOK manager screen"
	fi
	exit 1
fi
# udev and the driver need a moment to create the nodes
for _ in $(seq 50); do
	[ -e "/sys/bus/pci/drivers/$NAME/$bdf" ] && [ -n "$(ls "$dev"/video4linux 2>/dev/null)" ] && break
	sleep 0.1
done
if [ -e "/sys/bus/pci/drivers/$NAME/$bdf" ]; then
	v=$(ls "$dev/video4linux" 2>/dev/null | head -1)
	a=$(cat "$dev"/sound/card*/id 2>/dev/null | head -1)
	say "the card is up: video /dev/${v:-?}, ALSA card ${a:-?}"
else
	say "warning: $NAME loaded but did not bind $bdf; see: sudo dmesg | grep $NAME"
	exit 1
fi
