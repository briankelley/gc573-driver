#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Build a Linux Mint regression VM by unattended install from the official ISO (Mint ships no
# cloud images). Boots the ISO's casper kernel/initrd directly with automatic-ubiquity and a
# preseed served from the host on the libvirt bridge.
# Usage: tools/vms/mint.sh <version> [edition] [IP]   e.g. tools/vms/mint.sh 22.3 cinnamon 192.168.122.45
# After the install, provisioning is applied offline with virt-customize (Ubiquity's success_command
# does not run in automatic mode). Same conventions as create.sh: UEFI w/o Secure Boot, no persistent
# card unless CARD=1, left shut off, retain policy.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
VER=${1:?usage: mint.sh <version> [edition] [IP]}
ED=${2:-cinnamon}
IP=${3:-}
NAME=${NAME:-gc573-mint${VER//./}}
MIRROR=${MIRROR:-https://mirror.csclub.uwaterloo.ca/linuxmint/stable}
ISO=linuxmint-$VER-$ED-64bit.iso
IMGDIR=/var/lib/libvirt/images
KEY=${KEY:-$HOME/.ssh/gc573-vm}
PORT=${PORT:-8573}
CARD=${CARD:-0}
BRIDGE_IP=${BRIDGE_IP:-192.168.122.1}
CARD_BDF=${CARD_BDF:-$(lspci -D -d 1461:0054 | awk '{print $1}' | head -n1)}

[ -n "$CARD_BDF" ] || { echo "GC573 not found" >&2; exit 1; }
if sudo virsh dominfo "$NAME" >/dev/null 2>&1; then echo "VM $NAME exists: retained, not touched" >&2; exit 1; fi
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C gc573-vm -f "$KEY"
work=$(mktemp -d); srv=
cleanup() { [ -n "$srv" ] && kill "$srv" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT

sum=$(curl -fsSL "$MIRROR/$VER/sha256sum.txt" | awk -v f="*$ISO" '$2 == f {print $1}')
[ -n "$sum" ] || { echo "no checksum for $ISO" >&2; exit 1; }
iso=$IMGDIR/$ISO
if [ ! -f "$iso" ]; then
  curl -fsSL -o "$work/iso" "$MIRROR/$VER/$ISO"
  echo "$sum  $work/iso" | sha256sum -c -
  sudo install -m 644 "$work/iso" "$iso"
fi
xorriso -osirrox on -indev "$iso" -extract /casper/vmlinuz "$work/vmlinuz" -extract /casper/initrd.lz "$work/initrd.lz" 2>/dev/null
sudo install -m 644 "$work/vmlinuz" "$IMGDIR/$NAME-vmlinuz"
sudo install -m 644 "$work/initrd.lz" "$IMGDIR/$NAME-initrd.lz"

mkdir "$work/www"
sed -e "s|@NAME@|$NAME|" -e "s|@PW@|$(openssl rand -hex 12)|" \
  "$HERE/mint.seed.in" > "$work/www/mint.seed"
python3 -m http.server "$PORT" --bind "$BRIDGE_IP" --directory "$work/www" >/dev/null 2>&1 &
srv=$!

sudo qemu-img create -q -f qcow2 "$IMGDIR/$NAME.qcow2" 40G
net="network=default,model=virtio"
if [ -n "$IP" ]; then
  mac=$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))
  sudo virsh net-update default add ip-dhcp-host "<host mac='$mac' name='$NAME' ip='$IP'/>" --live --config >/dev/null
  net="$net,mac=$mac"
fi
args="boot=casper automatic-ubiquity noprompt url=http://$BRIDGE_IP:$PORT/mint.seed debian-installer/locale=en_US.UTF-8 keyboard-configuration/layoutcode=us console=ttyS0,115200 console=tty0 ---"
sudo virt-install --name "$NAME" --memory 6144 --vcpus 4 --cpu host-passthrough --osinfo ubuntu24.04 \
  --boot loader=/usr/share/OVMF/OVMF_CODE_4M.fd,loader.readonly=yes,loader.type=pflash,loader.secure=no,nvram.template=/usr/share/OVMF/OVMF_VARS_4M.fd \
  --install kernel="$IMGDIR/$NAME-vmlinuz",initrd="$IMGDIR/$NAME-initrd.lz",kernel_args="$args",kernel_args_overwrite=yes \
  --disk "$IMGDIR/$NAME.qcow2",bus=virtio --disk "$iso",device=cdrom,readonly=on \
  --network "$net" --graphics vnc,listen=127.0.0.1 --video virtio \
  --serial file,path=/var/log/libvirt/qemu/$NAME-serial.log \
  --noautoconsole --wait 0 >/dev/null
echo "installing $NAME (unattended; powers off when done)..."
until [ "$(sudo virsh domstate "$NAME")" = "shut off" ]; do sleep 15; done
kill "$srv" 2>/dev/null || true; srv=
sudo virt-xml "$NAME" --remove-device --disk device=cdrom >/dev/null || true
sudo virt-xml "$NAME" --edit --boot kernel=,initrd=,cmdline= >/dev/null 2>&1 || true
sudo virt-customize -q -a "$IMGDIR/$NAME.qcow2" --network \
  --run-command 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server build-essential dkms git rsync pciutils v4l-utils edid-decode alsa-utils >/dev/null' \
  --run-command 'k=$(ls /lib/modules | sort -V | tail -1); DEBIAN_FRONTEND=noninteractive apt-get install -y -qq linux-headers-$k >/dev/null' \
  --run-command 'systemctl enable ssh' \
  --ssh-inject "dev:file:$KEY.pub" \
  --write '/etc/sudoers.d/90-dev:dev ALL=(ALL) NOPASSWD:ALL' --chmod '0440:/etc/sudoers.d/90-dev'
if [ "$CARD" = 1 ]; then sudo virt-xml "$NAME" --add-device --hostdev "$CARD_BDF" >/dev/null; fi
if [ -n "$IP" ] && ! grep -q "^Host $NAME\$" ~/.ssh/config 2>/dev/null; then
  printf '\nHost %s\n    HostName %s\n    User dev\n    IdentityFile %s\n    StrictHostKeyChecking accept-new\n    UserKnownHostsFile ~/.ssh/known_hosts.gc573\n    ServerAliveInterval 15\n' \
    "$NAME" "$IP" "$KEY" >> ~/.ssh/config
fi
echo "$NAME installed and provisioned; shut off"
