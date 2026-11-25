#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Remove the GC573 driver that tools/install.sh installed, and undo the
# binding install.sh made:
# - gc573 for this boot only (install.sh --this-boot): the saved driverctl
#   override is loaded again now (driverctl load-override), as a reboot
#   would do;
# - the override removed for good (install.sh --permanent): put back as it
#   was. Asks first on a terminal; --yes skips that; without a terminal and
#   without --yes it only prints the command.
# Then gc573 is unloaded (if nothing has the card open), every gc573
# version is removed from DKMS, with its sources in /usr/src, and the
# modprobe.d entry install.sh may have left is removed.
# Usage: sudo tools/uninstall.sh [--yes]
set -euo pipefail

NAME=gc573
STATE_DIR=/var/lib/gc573-install
STATE=$STATE_DIR/state
NOLOAD=/etc/modprobe.d/gc573-no-autoload.conf

say() { printf '%s\n' "$*"; }
die() { printf 'uninstall.sh: %s\n' "$*" >&2; exit 1; }

yes=0
for a in "$@"; do
	case $a in
	--yes|-y) yes=1 ;;
	-h|--help) sed -n '3,/^set -euo/{/^set -euo/d; s/^# \{0,1\}//; p}' "$0"; exit 0 ;;
	*) die "unknown option $a (see --help)" ;;
	esac
done

[ "$(id -u)" = 0 ] || exec sudo -- "$0" "$@"
command -v dkms > /dev/null || die "dkms is not installed: nothing to remove with it"

unload() {
	grep -q "^$NAME " /proc/modules || return 0
	modprobe -r "$NAME" 2>/dev/null
}
bound() { if [ -L "/sys/bus/pci/devices/$1/driver" ]; then basename "$(readlink "/sys/bus/pci/devices/$1/driver")"; fi; }

inuse=0
if grep -q "^$NAME " /proc/modules; then
	if unload; then
		say "unloaded $NAME"
	else
		inuse=1
	fi
fi

# ---- the binding install.sh made (state: "bind MODE DEVICE DRIVER"; an
# older install.sh wrote "override DEVICE DRIVER" for a removed override)
if [ -f "$STATE" ]; then
	read -r what a b c < "$STATE" || true
	case $what in
	bind) mode=$a bdf=$b drv=$c ;;
	override) mode=permanent bdf=$a drv=$b ;;
	*) mode= ;;
	esac
	case $mode in
	this-boot)
		saved=$(cat "/etc/driverctl.d/pci-$bdf" 2>/dev/null || true)
		now=$(cat "/sys/bus/pci/devices/$bdf/driver_override" 2>/dev/null || true)
		if [ "$now" != "$NAME" ] && [ "$(bound "$bdf")" != "$NAME" ]; then
			say "$NAME does not have the card (a reboot gave it back to ${saved:-its saved driver}, or $NAME never took it): nothing to undo"
		elif [ -z "$saved" ] || ! command -v driverctl > /dev/null; then
			say "warning: the saved driverctl override for $bdf is gone, so there is nothing to load again; the card stays as it is until a reboot"
		else
			[ "$inuse" = 0 ] || say "$NAME is in use: the applications using the card (PipeWire too) lose it now"
			# judged by the result: driverctl exits 1 when the driver
			# cannot take the card at once (vfio-pci without an IOMMU)
			driverctl load-override "$bdf" > /dev/null 2>&1 || true
			now=$(cat "/sys/bus/pci/devices/$bdf/driver_override" 2>/dev/null || true)
			if [ "$now" = "$saved" ]; then
				b=$(bound "$bdf")
				say "the saved override is loaded again: $bdf -> $saved (bound now: ${b:-no driver; $saved takes it when a virtual machine starts with it or at the next boot})"
			else
				say "warning: could not load the saved override; run: sudo driverctl load-override $bdf (or reboot)"
			fi
		fi ;;
	permanent)
		say ""
		say "install.sh removed a driverctl override that bound $bdf to $drv."
		ans=n
		if [ "$yes" = 1 ]; then
			ans=y
		elif [ -t 0 ] && [ -t 1 ]; then
			read -r -p "Put it back now (the card goes back to $drv)? [Y/n] " ans || ans=n
			[ -n "$ans" ] || ans=y
		else
			say "(no terminal and no --yes: not changing it)"
		fi
		case $ans in
		y|Y|yes|YES)
			[ "$inuse" = 0 ] || say "$NAME is in use: the applications using the card (PipeWire too) lose it now"
			# --noprobe: without it driverctl does not save the override
			# when the driver cannot take the card at once; probe after
			if command -v driverctl > /dev/null &&
			   driverctl --noprobe set-override "$bdf" "$drv" > /dev/null 2>&1 &&
			   [ "$(cat "/etc/driverctl.d/pci-$bdf" 2>/dev/null)" = "$drv" ]; then
				echo "$bdf" > /sys/bus/pci/drivers_probe 2>/dev/null || true
				b=$(bound "$bdf")
				say "override restored: $bdf -> $drv (the card is bound to ${b:-no driver now; $drv takes it at the next boot or when a virtual machine starts with it})"
			else
				say "warning: could not restore it; run: sudo driverctl set-override $bdf $drv"
			fi ;;
		*)
			say "left as it is. To restore it later: sudo driverctl set-override $bdf $drv" ;;
		esac ;;
	esac
fi
# without the card any more, gc573 can go now
if [ "$inuse" = 1 ]; then
	if unload; then
		say "unloaded $NAME"
	else
		say "warning: $NAME is in use (close the applications using the card; PipeWire holds it too); it stays loaded until the next reboot"
	fi
fi

# ---- DKMS ----
found=0
if [ -d "/var/lib/dkms/$NAME" ]; then
	for d in /var/lib/dkms/$NAME/*/; do
		v=$(basename "$d")
		case $v in kernel-*) continue ;; esac
		say "removing $NAME $v from DKMS (all kernels)"
		dkms remove -m "$NAME" -v "$v" --all > /dev/null 2>&1 ||
			say "warning: dkms remove $NAME/$v failed"
		rm -rf "/usr/src/$NAME-$v"
		found=1
	done
	rmdir "/var/lib/dkms/$NAME" 2>/dev/null || true
fi
[ "$found" = 1 ] || say "no $NAME in DKMS"
# RHEL family: weak-modules links the module into the other installed
# kernels (weak-updates/); dkms remove leaves those links behind
for l in /lib/modules/*/weak-updates/"$NAME".ko*; do
	{ [ -L "$l" ] || [ -e "$l" ]; } || continue
	k=${l#/lib/modules/}
	k=${k%%/*}
	rm -f "$l"
	depmod -a "$k" 2>/dev/null || true
	say "removed the weak-modules link $l"
done
left=$(find /lib/modules -name "$NAME.ko*" -path '*dkms*' 2>/dev/null || true)
[ -z "$left" ] || say "warning: module files left behind: $left"
depmod -a 2>/dev/null || true
if [ -f "$NOLOAD" ]; then
	rm -f "$NOLOAD"
	say "removed $NOLOAD"
fi
rm -f "$STATE"
rmdir "$STATE_DIR" 2>/dev/null || true
say "done"
