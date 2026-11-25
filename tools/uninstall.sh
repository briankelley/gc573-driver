#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Remove the GC573 driver that tools/install.sh installed: unload it (if no
# application has the card open), remove every gc573 version from DKMS and
# its sources from /usr/src, and offer to put back a driverctl override
# that install.sh removed (for example the one that gives the card to
# virtual machines through vfio-pci).
# Usage: sudo tools/uninstall.sh
set -euo pipefail

NAME=gc573
STATE_DIR=/var/lib/gc573-install
STATE=$STATE_DIR/state

say() { printf '%s\n' "$*"; }
die() { printf 'uninstall.sh: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || exec sudo -- "$0" "$@"
command -v dkms > /dev/null || die "dkms is not installed: nothing to remove with it"

if grep -q "^$NAME " /proc/modules; then
	if modprobe -r "$NAME" 2>/dev/null; then
		say "unloaded $NAME"
	else
		say "warning: $NAME is in use (close the applications using the card); it stays loaded until the next reboot"
	fi
fi

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

if [ -f "$STATE" ]; then
	mapfile -t lines < "$STATE"
	for line in "${lines[@]}"; do
		read -r what bdf drv <<< "$line"
		[ "$what" = override ] || continue
		say ""
		say "install.sh removed a driverctl override that bound $bdf to $drv."
		ans=y
		if [ -t 0 ] && [ -t 1 ]; then
			read -r -p "Put it back now (the card goes back to $drv)? [Y/n] " ans || ans=n
		else
			say "(not asking: no terminal)"
			ans=n
		fi
		case $ans in
		""|y|Y|yes|YES)
			if command -v driverctl > /dev/null && driverctl set-override "$bdf" "$drv"; then
				say "override restored: $bdf -> $drv"
			else
				say "warning: could not restore it; run: sudo driverctl set-override $bdf $drv"
			fi ;;
		*)
			say "left as it is. To restore it later: sudo driverctl set-override $bdf $drv" ;;
		esac
	done
	rm -f "$STATE"
	rmdir "$STATE_DIR" 2>/dev/null || true
fi
say "done"
