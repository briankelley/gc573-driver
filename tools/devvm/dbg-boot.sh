#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Boot gc573-dev once into the debug kernel (tools/devvm/debug-kernel.sh),
# optionally with extra kernel arguments for that boot only, or back into
# its default entry, the generic kernel:
#   tools/devvm/dbg-boot.sh              the debug entry as installed
#   tools/devvm/dbg-boot.sh threadirqs   the same with "threadirqs"
#   tools/devvm/dbg-boot.sh --generic    a plain reboot, the default entry
# Extra arguments go into a GRUB entry of their own, "gc573 debug: ARGS",
# copied from the debug kernel's entry with the arguments added to its
# linux line (/etc/grub.d/42_gc573-dbg-args, rewritten each time).
# grub-reboot picks the entry for the next boot only; the default stays
# the generic kernel. The reboot turns the card's bus mastering off (QEMU's
# VFIO reset), so it happens only if tools/vms/card-idle.sh says the card
# is idle (spec/pci.md). Waits for the VM to come back, then prints the
# running kernel and its command line. The card stays with the VM.
set -euo pipefail

VM=${VM:-gc573-dev}
for a in "$@"; do
	case $a in
	*[!A-Za-z0-9_.,=:/-]*) echo "dbg-boot.sh: argument '$a' has characters GRUB would need quoted" >&2; exit 2 ;;
	esac
done

"$(cd "$(dirname "$0")" && pwd)/../vms/card-idle.sh" "$VM" ||
	{ echo "dbg-boot.sh: $VM not rebooted: the card is not idle" >&2; exit 1; }

ssh -o BatchMode=yes "$VM" sudo bash -s -- "$@" <<'EOS'
set -euo pipefail
entry=$(cat /etc/gc573-dbg-entry)	# "submenu>title" (debug-kernel.sh)
if [ "${1:-}" = --generic ]; then
	[ $# -eq 1 ] || { echo "--generic takes no kernel arguments" >&2; exit 2; }
	echo "next boot: the default entry"
elif [ $# -eq 0 ]; then
	grub-reboot "$entry"
	echo "next boot: $entry"
else
	t=${entry#*>}
	cfg=/boot/grub/grub.cfg
	block=$(awk -v t="$t" '
		!on && index($0, "menuentry '\''" t "'\''") { on = 1 }
		on { print }
		on && /^[[:space:]]*}[[:space:]]*$/ { exit }' "$cfg")
	[ -n "$block" ] || { echo "no GRUB entry '$t'" >&2; exit 1; }
	title="gc573 debug: $*"
	f=/etc/grub.d/42_gc573-dbg-args
	{
		echo '#!/bin/sh'
		echo 'exec tail -n +3 $0'
		sed -e "1s/menuentry '[^']*'/menuentry '$title'/" \
		    -e "1s/\$menuentry_id_option '[^']*'/\$menuentry_id_option 'gc573-dbg-args'/" \
		    -e "/^[[:space:]]*linux[[:space:]]/s|\$| $*|" <<< "$block"
	} > "$f"
	chmod 755 "$f"
	update-grub > /dev/null 2>&1
	grep -q "menuentry '$title'" "$cfg" || { echo "update-grub did not take $f" >&2; exit 1; }
	grub-reboot "$title"
	echo "next boot: $title"
fi
systemd-run --on-active=1 systemctl reboot > /dev/null
EOS

sleep 20
for i in $(seq 60); do
	ssh -o BatchMode=yes -o ConnectTimeout=5 "$VM" true 2> /dev/null && break
	sleep 5
done
ssh -o BatchMode=yes "$VM" 'echo "running: $(uname -r)"; echo "cmdline: $(cat /proc/cmdline)"'
