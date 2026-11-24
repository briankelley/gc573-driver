#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Build a GC573 passthrough VM. Default: reference VM `gc573-ref` (Ubuntu 20.04 / kernel 5.4).
# UEFI w/o Secure Boot. Env: NAME RELEASE OSINFO USERDATA START (START=0: provision only;
# card can be attached to one running VM at a time). Prereq: tools/host-setup.sh. Run as normal user with sudo.
set -euo pipefail

NAME=${NAME:-gc573-ref}
RELEASE=${RELEASE:-focal}
OSINFO=${OSINFO:-ubuntu20.04}
START=${START:-1}
IMGDIR=/var/lib/libvirt/images
BASE_URL=https://cloud-images.ubuntu.com/$RELEASE/current
BASE_IMG=$RELEASE-server-cloudimg-amd64.img
KEY=${KEY:-$HOME/.ssh/gc573-vm}
CARD_BDF=${CARD_BDF:-$(lspci -D -d 1461:0054 | awk '{print $1}' | head -n1)}
HERE=$(cd "$(dirname "$0")" && pwd)
USERDATA=${USERDATA:-$HERE/user-data.in}

[ -n "$CARD_BDF" ] || { echo "GC573 not found" >&2; exit 1; }
if sudo virsh dominfo "$NAME" >/dev/null 2>&1; then
  echo "VM $NAME exists. Remove: sudo virsh destroy $NAME; sudo virsh undefine $NAME --nvram --tpm" >&2; exit 1
fi
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C "$NAME" -f "$KEY"

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# base image, sha256 verified
if [ ! -f "$IMGDIR/$RELEASE-base.img" ]; then
  curl -fsSL -o "$work/$BASE_IMG" "$BASE_URL/$BASE_IMG"
  sum=$(curl -fsSL "$BASE_URL/SHA256SUMS" | awk -v f="*$BASE_IMG" '$2==f{print $1}')
  echo "$sum  $work/$BASE_IMG" | sha256sum -c -
  sudo install -m 644 "$work/$BASE_IMG" "$IMGDIR/$RELEASE-base.img"
fi

# NoCloud seed (virt-install --cloud-init proved unreliable here)
sed "s|@SSH_PUBKEY@|$(cat "$KEY.pub")|" "$USERDATA" > "$work/user-data"
printf 'instance-id: %s\nlocal-hostname: %s\n' "$NAME" "$NAME" > "$work/meta-data"
printf 'version: 2\nethernets:\n  nic0:\n    match: {name: "en*"}\n    dhcp4: true\n' > "$work/network-config"
cloud-localds -N "$work/network-config" "$work/seed.iso" "$work/user-data" "$work/meta-data"
sudo install -m 644 "$work/seed.iso" "$IMGDIR/$NAME-seed.iso"
sudo qemu-img create -q -f qcow2 -F qcow2 -b "$IMGDIR/$RELEASE-base.img" "$IMGDIR/$NAME.qcow2" 40G

# Non-SB OVMF: lockdown=none needed for unsigned modules + mmiotrace.
sudo virt-install --name "$NAME" --memory 8192 --vcpus 4 --cpu host-passthrough --osinfo "$OSINFO" \
  --boot loader=/usr/share/OVMF/OVMF_CODE_4M.fd,loader.readonly=yes,loader.type=pflash,loader.secure=no,nvram.template=/usr/share/OVMF/OVMF_VARS_4M.fd \
  --disk "$IMGDIR/$NAME.qcow2",bus=virtio --disk "$IMGDIR/$NAME-seed.iso",device=cdrom \
  --network network=default,model=virtio --graphics spice --video virtio \
  --serial file,path=/var/log/libvirt/qemu/$NAME-serial.log \
  --noautoconsole --import

echo "provisioning (cloud-init; VM powers off when done)..."
until [ "$(sudo virsh domstate "$NAME")" = "shut off" ]; do sleep 10; done

# post-provision: drop seed, attach card
sudo virt-xml "$NAME" --remove-device --disk device=cdrom
sudo virt-xml "$NAME" --add-device --hostdev "$CARD_BDF"
if [ "$START" != 1 ]; then echo "provisioned; card attached; not started (START=0)"; exit 0; fi
sudo virsh start "$NAME"

echo "verify:"
until ip=$(sudo virsh domifaddr "$NAME" | awk '/ipv4/{split($4,a,"/");print a[1]}') && [ -n "$ip" ] \
  && ssh -q -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new -i "$KEY" dev@"$ip" true; do sleep 5; done
ssh -i "$KEY" dev@"$ip" 'uname -r; cat /sys/kernel/security/lockdown; lspci -nn -d 1461:0054'
echo "ssh -i $KEY dev@$ip"
