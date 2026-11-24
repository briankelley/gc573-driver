#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Host tooling for gc573-driver development. Idempotent. Run as normal user with sudo.
# Target host: Ubuntu 24.04 / Linux Mint 22, x86_64, VT-d enabled.
set -euo pipefail

GHIDRA_VER=12.2
GHIDRA_ZIP=ghidra_12.2_PUBLIC_20261016.zip
GHIDRA_SHA256=2c2cd776db3c1f6a097ba418922378ac3649cadd5e844a6f5f088ae628a7be67
GHIDRA_URL=https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_VER}_build/${GHIDRA_ZIP}
CARD_BDF=${CARD_BDF:-}   # auto-detected if empty

say() { printf '\n== %s\n' "$*"; }

say "apt packages"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
  qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst virt-manager \
  ovmf cloud-image-utils driverctl v4l-utils openjdk-25-jdk unzip curl git \
  build-essential dkms linux-headers-"$(uname -r)" linux-modules-extra-"$(uname -r)" \
  libguestfs-tools xorriso edid-decode gh \
  flex bison libssl-dev libelf-dev bc dwarves dpkg-dev debhelper fakeroot zstd cpio rsync

say "OBS (obsproject PPA)"
if ! ls /etc/apt/sources.list.d/ | grep -q obsproject; then
  sudo add-apt-repository -y ppa:obsproject/obs-studio
fi
sudo apt-get update -qq   # add-apt-repository on Mint does not always refresh
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q obs-studio
apt-cache policy obs-studio | grep -q 'Installed:.*obsproject' || { echo "OBS not from PPA" >&2; exit 1; }

say "Ghidra ${GHIDRA_VER}"
if [ ! -d "/opt/ghidra_${GHIDRA_VER}_PUBLIC" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/$GHIDRA_ZIP" "$GHIDRA_URL"
  echo "$GHIDRA_SHA256  $tmp/$GHIDRA_ZIP" | sha256sum -c -
  sudo unzip -q "$tmp/$GHIDRA_ZIP" -d /opt
fi
sudo ln -sfn "/opt/ghidra_${GHIDRA_VER}_PUBLIC" /opt/ghidra
sudo ln -sf /opt/ghidra/ghidraRun /usr/local/bin/ghidra
sudo ln -sf /opt/ghidra/support/analyzeHeadless /usr/local/bin/ghidra-headless

say "libvirt"
sudo usermod -aG libvirt,kvm "$USER"
sudo systemctl enable --now libvirtd

say "IOMMU + card"
[ -d /sys/kernel/iommu_groups/0 ] || { echo "IOMMU off: enable VT-d / intel_iommu=on" >&2; exit 1; }
if [ -z "$CARD_BDF" ]; then
  CARD_BDF=$(lspci -D -d 1461:0054 | awk '{print $1}' | head -n1)
fi
[ -n "$CARD_BDF" ] || { echo "GC573 (1461:0054) not found" >&2; exit 1; }
grp=$(basename "$(readlink -f /sys/bus/pci/devices/$CARD_BDF/iommu_group)")
n=$(ls /sys/kernel/iommu_groups/$grp/devices | wc -l)
[ "$n" -eq 1 ] || { echo "card shares IOMMU group $grp with $n devices; passthrough needs ACS fix" >&2; exit 1; }
sudo driverctl set-override "$CARD_BDF" vfio-pci
lspci -k -s "$CARD_BDF" | grep -E 'in use: vfio-pci' >/dev/null || { echo "vfio-pci bind failed" >&2; exit 1; }

say "done. card $CARD_BDF -> vfio-pci (undo: sudo driverctl unset-override $CARD_BDF). Re-login for libvirt group."
