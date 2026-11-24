#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Move the GC573 between running VMs by PCI hot-unplug / hot-plug (libvirt live detach/attach).
# Usage: tools/vms/card.sh <vm>     attach to running <vm>, detaching it from the running VM that holds it
#        tools/vms/card.sh --where  print the running VM that holds it
# Detach waits for the guest to release the device: a driver whose remove() hangs fails here.
# Matrix VMs carry no persistent hostdev; gc573-dev / gc573-ref do (they claim the card at start).
set -euo pipefail
CARD_BDF=${CARD_BDF:-$(lspci -D -d 1461:0054 | awk '{print $1}' | head -n1)}
IFS=':.' read -r d b s f <<< "$CARD_BDF"
src="<address domain='0x$d' bus='0x$b' slot='0x$s' function='0x$f'/>"
xml=$(mktemp); trap 'rm -f "$xml"' EXIT
printf "<hostdev mode='subsystem' type='pci' managed='yes'><source>%s</source></hostdev>\n" "$src" > "$xml"
holder() {
  for v in $(sudo virsh list --name); do
    sudo virsh dumpxml "$v" | grep -qF "$src" && echo "$v"
  done
  return 0
}
if [ "${1:-}" = --where ]; then holder; exit 0; fi
to=${1:?usage: card.sh <vm> | --where}
[ "$(sudo virsh domstate "$to")" = running ] || { echo "$to is not running" >&2; exit 1; }
for v in $(holder); do
  [ "$v" = "$to" ] && { echo "$to already holds the card"; exit 0; }
  sudo virsh detach-device "$v" "$xml" --live >/dev/null
  for _ in $(seq 1 30); do holder | grep -qx "$v" || break; sleep 1; done
  if holder | grep -qx "$v"; then echo "detach from $v timed out (guest did not release the device)" >&2; exit 1; fi
done
sudo virsh attach-device "$to" "$xml" --live >/dev/null
echo "card now in: $(holder)"
