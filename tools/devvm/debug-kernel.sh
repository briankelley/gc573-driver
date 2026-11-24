#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Debug kernel for gc573-dev: Ubuntu source of the VM's GA kernel + kmemleak, lockdep,
# sleep-in-atomic checks, KASAN, DMA-API debug. (DEBUG_OBJECTS off: Ubuntu 6.8.0-151's
# lib/debugobjects.c uses __data_racy, undefined in that tree.) Built on the host
# (localmodconfig from the VM's modules), installed in the VM as an extra boot entry.
# Default boot stays the generic kernel. Boot debug once:
#   ssh gc573-dev 'sudo grub-reboot "$(cat /etc/gc573-dbg-entry)" && sudo reboot'
# Prereq: gc573-dev running, ssh alias gc573-dev. Run as normal user with sudo.
set -euo pipefail

VM=${VM:-gc573-dev}
UBUVER=${UBUVER:-6.8.0-151.151}        # Ubuntu source version; match the VM's GA kernel
ORIG=${ORIG:-linux_6.8.0.orig.tar.gz}
WORK=${WORK:-/var/tmp/gc573-dbg-kernel} # not on eCryptfs home: faster
SUFFIX=${SUFFIX:-gc573dbg}
LP=https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/linux/$UBUVER

sudo apt-get install -y -qq flex bison libssl-dev libelf-dev bc dwarves dpkg-dev debhelper fakeroot zstd cpio rsync >/dev/null
mkdir -p "$WORK"; cd "$WORK"
for f in "linux_$UBUVER.dsc" "$ORIG" "linux_$UBUVER.diff.gz"; do
  [ -f "$f" ] || curl -fsSL -o "$f" "$LP/$f"
done
src=linux-$UBUVER
if [ ! -d "$src" ]; then
  dpkg-source -x "linux_$UBUVER.dsc" "$src"   # checks orig/diff hashes against .dsc
  mv "$src/debian" "$src/debian.ubuntu"       # bindeb-pkg writes its own debian/
fi

# modules the VM needs: loaded set + media/sound stack the driver uses
ssh "$VM" 'sudo modprobe -a videodev videobuf2_dma_sg videobuf2_vmalloc videobuf2_v4l2 v4l2_dv_timings snd_pcm; lsmod' > lsmod.vm
ssh "$VM" 'cat /boot/config-$(uname -r)' > "$src/.config"
cd "$src"
make -s LSMOD=../lsmod.vm localmodconfig < <(yes '') >/dev/null   # pipefail-safe
scripts/config \
  -e DEBUG_KMEMLEAK -d DEBUG_KMEMLEAK_DEFAULT_OFF --set-val DEBUG_KMEMLEAK_MEM_POOL_SIZE 16000 \
  -e PROVE_LOCKING -e DEBUG_ATOMIC_SLEEP -e DEBUG_LIST -e DEBUG_SG \
  -e DMA_API_DEBUG -e DMA_API_DEBUG_SG \
  -e KASAN -e KASAN_GENERIC -e KASAN_INLINE \
  -d DEBUG_OBJECTS \
  -d DEBUG_INFO_DWARF5 -d DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT -e DEBUG_INFO_NONE -d DEBUG_INFO_BTF \
  -d MODULE_SIG_FORCE \
  --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS "" \
  --set-str LOCALVERSION "" -d LOCALVERSION_AUTO
make -s olddefconfig
for o in DEBUG_KMEMLEAK PROVE_LOCKING DEBUG_ATOMIC_SLEEP KASAN DMA_API_DEBUG; do
  grep -q "^CONFIG_$o=y" .config || { echo "config: $o not enabled" >&2; exit 1; }
done
make -s -j"$(nproc)" bindeb-pkg LOCALVERSION="-$SUFFIX" >/dev/null
cd ..
krel=$(make -s --no-print-directory -C "$src" kernelrelease LOCALVERSION="-$SUFFIX")
debs=$(ls linux-image-"$krel"_*.deb linux-headers-"$krel"_*.deb)
scp -q $debs "$VM":/tmp/
# install; pin default boot to the generic kernel; record the debug entry name
# shellcheck disable=SC2046
ssh "$VM" sudo bash -s -- "$krel" $(for d in $debs; do printf '/tmp/%s ' "$d"; done) <<'EOS'
set -euo pipefail
krel=$1; shift
dpkg -i "$@" >/dev/null
# Ubuntu's top Makefile adds -I ubuntu/include; bindeb-pkg headers lack the dir (W=1: -Wmissing-include-dirs)
mkdir -p "$(readlink -f /lib/modules/$krel/build)/ubuntu/include"
sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
update-grub >/dev/null 2>&1
cfg=/boot/grub/grub.cfg
sub=$(grep -m1 "^submenu '" "$cfg" | cut -d"'" -f2)
t_gen=$(grep -m1 "menuentry 'Ubuntu, with Linux $(uname -r)'" "$cfg" | cut -d"'" -f2)
t_dbg=$(grep -m1 "menuentry 'Ubuntu, with Linux $krel'" "$cfg" | cut -d"'" -f2)
[ -n "$sub" ] && [ -n "$t_gen" ] && [ -n "$t_dbg" ] || { echo "grub entries not found" >&2; exit 1; }
grub-set-default "$sub>$t_gen"
echo "$sub>$t_dbg" > /etc/gc573-dbg-entry
grub-editenv list
EOS
echo "installed $krel in $VM"
