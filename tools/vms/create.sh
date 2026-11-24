#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Build a regression-matrix VM from a profile (tools/vms/profiles/<profile>.env).
# Usage: tools/vms/create.sh <profile> [IP]      e.g. tools/vms/create.sh alma9 192.168.122.41
# Profile vars: NAME OSINFO IMG_URL SUM_URL USERDATA (template under tools/vms/).
# Cloud image sha256-verified (BSD "SHA256 (f) = h" or GNU "h  f" CHECKSUM formats). Disk is a
# standalone copy (no shared backing file) so retained VMs never depend on a re-downloadable base.
# UEFI without Secure Boot. No persistent hostdev (move the card in with card.sh; CARD=1 attaches it
# persistently). VM left shut off (START=1 boots it).
# Retain policy (AGENTS.md): refuses to touch an existing VM.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PROFILE=${1:?usage: create.sh <profile> [IP]}
IP=${2:-}
# shellcheck source=/dev/null
. "$HERE/profiles/$PROFILE.env"
IMGDIR=/var/lib/libvirt/images
KEY=${KEY:-$HOME/.ssh/gc573-vm}
START=${START:-0}
CARD=${CARD:-0}
CARD_BDF=${CARD_BDF:-$(lspci -D -d 1461:0054 | awk '{print $1}' | head -n1)}

[ -n "$CARD_BDF" ] || { echo "GC573 not found" >&2; exit 1; }
if sudo virsh dominfo "$NAME" >/dev/null 2>&1; then
  echo "VM $NAME exists: retained, not touched" >&2; exit 1
fi
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C gc573-vm -f "$KEY"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

f=$(basename "$IMG_URL")
sum=$(curl -fsSL "$SUM_URL" | awk -v f="$f" '
  $1 == "SHA256" && $2 == "(" f ")" {print $4; exit}
  $2 == f || $2 == "*" f {print $1; exit}')
[ -n "$sum" ] || { echo "no checksum for $f" >&2; exit 1; }
base=$IMGDIR/base-${f%.qcow2}-${sum:0:12}.qcow2
if [ ! -f "$base" ]; then
  curl -fsSL -o "$work/img" "$IMG_URL"
  echo "$sum  $work/img" | sha256sum -c -
  sudo install -m 644 "$work/img" "$base"
fi

sed -e "s|@SSH_PUBKEY@|$(cat "$KEY.pub")|" -e "s|@NAME@|$NAME|" "$HERE/$USERDATA" > "$work/user-data"
printf 'instance-id: %s\nlocal-hostname: %s\n' "$NAME" "$NAME" > "$work/meta-data"
printf 'version: 2\nethernets:\n  nic0:\n    match: {name: "e*"}\n    dhcp4: true\n' > "$work/network-config"
cloud-localds -N "$work/network-config" "$work/seed.iso" "$work/user-data" "$work/meta-data"
sudo install -m 644 "$work/seed.iso" "$IMGDIR/$NAME-seed.iso"
sudo qemu-img convert -q -O qcow2 "$base" "$IMGDIR/$NAME.qcow2"
sudo qemu-img resize -q "$IMGDIR/$NAME.qcow2" 40G

net="network=default,model=virtio"
if [ -n "$IP" ]; then
  mac=$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))
  sudo virsh net-update default add ip-dhcp-host "<host mac='$mac' name='$NAME' ip='$IP'/>" --live --config >/dev/null
  net="$net,mac=$mac"
fi
sudo virt-install --name "$NAME" --memory 6144 --vcpus 4 --cpu host-passthrough --osinfo "$OSINFO" \
  --boot loader=/usr/share/OVMF/OVMF_CODE_4M.fd,loader.readonly=yes,loader.type=pflash,loader.secure=no,nvram.template=/usr/share/OVMF/OVMF_VARS_4M.fd \
  --disk "$IMGDIR/$NAME.qcow2",bus=virtio --disk "$IMGDIR/$NAME-seed.iso",device=cdrom \
  --network "$net" --graphics vnc,listen=127.0.0.1 --video virtio \
  --serial file,path=/var/log/libvirt/qemu/$NAME-serial.log \
  --noautoconsole --import >/dev/null
echo "provisioning $NAME (cloud-init; powers off when done)..."
until [ "$(sudo virsh domstate "$NAME")" = "shut off" ]; do sleep 10; done
sudo virt-xml "$NAME" --remove-device --disk device=cdrom >/dev/null
if [ "$CARD" = 1 ]; then sudo virt-xml "$NAME" --add-device --hostdev "$CARD_BDF" >/dev/null; fi
if [ -n "$IP" ] && ! grep -q "^Host $NAME\$" ~/.ssh/config 2>/dev/null; then
  printf '\nHost %s\n    HostName %s\n    User dev\n    IdentityFile %s\n    StrictHostKeyChecking accept-new\n    UserKnownHostsFile ~/.ssh/known_hosts.gc573\n    ServerAliveInterval 15\n' \
    "$NAME" "$IP" "$KEY" >> ~/.ssh/config
fi
if [ "$START" = 1 ]; then sudo virsh start "$NAME" >/dev/null; fi
echo "$NAME provisioned; card $([ "$CARD" = 1 ] && echo attached || echo "not attached (card.sh)"); $([ "$START" = 1 ] && echo started || echo 'shut off (START=1 to boot)')"
