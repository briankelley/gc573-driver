#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Debug kernel for gc573-dev: Ubuntu source of the VM's GA kernel + kmemleak, lockdep,
# sleep-in-atomic checks, KASAN, DMA-API debug, UBSAN (bounds and shift checks, as
# Ubuntu's config has them, now required; not alignment, and reports rather than
# traps) and fault injection (failslab, fail_page_alloc, their debugfs files and the
# stacktrace filter that aims them at one module: tests/cases/18-fault-inject.sh).
# (DEBUG_OBJECTS off: Ubuntu 6.8.0-151's
# lib/debugobjects.c uses __data_racy, undefined in that tree.) Built on the host
# (localmodconfig from the VM's modules), installed in the VM as an extra boot entry.
# Default boot stays the generic kernel. Boot debug once:
#   ssh gc573-dev 'sudo grub-reboot "$(cat /etc/gc573-dbg-entry)" && sudo reboot'
# Prereq: gc573-dev running, ssh alias gc573-dev. Run as normal user with sudo.
# Without the VM (gc573-dev holds the card's hostdev, so it starts only when
# the card may go to it): VMCONFIG=FILE (the VM's /boot/config of its
# running kernel; the host's own when it runs the same Ubuntu build) and
# VMLSMOD=FILE (an lsmod of the VM, as this script saves in $WORK/lsmod.vm)
# with INSTALL=0 build the packages only; INSTALL=only later installs the
# newest packages built, with the VM running.
set -euo pipefail

VM=${VM:-gc573-dev}
UBUVER=${UBUVER:-6.8.0-151.151}        # Ubuntu source version; match the VM's GA kernel
ORIG=${ORIG:-linux_6.8.0.orig.tar.gz}
WORK=${WORK:-/var/tmp/gc573-dbg-kernel} # not on eCryptfs home: faster
SUFFIX=${SUFFIX:-gc573dbg}
INSTALL=${INSTALL:-1}                   # 1: build and install; 0: build only; only
VMCONFIG=${VMCONFIG:-}
VMLSMOD=${VMLSMOD:-}
LP=https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/linux/$UBUVER

mkdir -p "$WORK"; cd "$WORK"
src=linux-$UBUVER
if [ "$INSTALL" != only ]; then
sudo apt-get install -y -qq flex bison libssl-dev libelf-dev bc dwarves dpkg-dev debhelper fakeroot zstd cpio rsync >/dev/null
for f in "linux_$UBUVER.dsc" "$ORIG" "linux_$UBUVER.diff.gz"; do
  [ -f "$f" ] || curl -fsSL -o "$f" "$LP/$f"
done
if [ ! -d "$src" ]; then
  dpkg-source -x "linux_$UBUVER.dsc" "$src"   # checks orig/diff hashes against .dsc
  mv "$src/debian" "$src/debian.ubuntu"       # bindeb-pkg writes its own debian/
fi

# modules the VM needs: loaded set + media/sound stack the driver uses
if [ -n "$VMLSMOD" ]; then
  [ "$(readlink -f "$VMLSMOD")" = "$(readlink -f lsmod.vm)" ] || cp "$VMLSMOD" lsmod.vm
else
  ssh "$VM" 'sudo modprobe -a videodev videobuf2_dma_sg videobuf2_vmalloc videobuf2_v4l2 v4l2_dv_timings snd_pcm; lsmod' > lsmod.vm
fi
if [ -n "$VMCONFIG" ]; then
  cp "$VMCONFIG" "$src/.config"
else
  ssh "$VM" 'cat /boot/config-$(uname -r)' > "$src/.config"
fi
cd "$src"
make -s LSMOD=../lsmod.vm localmodconfig < <(yes '') >/dev/null   # pipefail-safe
# localmodconfig keeps loaded modules' own options, but VIDEOBUF2_* are hidden
# symbols that only drivers select, so they went with the unloaded drivers:
# vivid selects the vb2 stack gc573 needs (and is a v4l2-compliance reference).
scripts/config \
  -m VIDEO_VIVID \
  -e DEBUG_KMEMLEAK -d DEBUG_KMEMLEAK_DEFAULT_OFF --set-val DEBUG_KMEMLEAK_MEM_POOL_SIZE 16000 \
  -e PROVE_LOCKING -e DEBUG_ATOMIC_SLEEP -e DEBUG_LIST -e DEBUG_SG \
  -e DMA_API_DEBUG -e DMA_API_DEBUG_SG \
  -e KASAN -e KASAN_GENERIC -e KASAN_INLINE \
  -e UBSAN -e UBSAN_BOUNDS -e UBSAN_SHIFT -d UBSAN_ALIGNMENT -d UBSAN_TRAP \
  -e FAULT_INJECTION -e FAILSLAB -e FAIL_PAGE_ALLOC -e FAULT_INJECTION_DEBUG_FS \
  -e FAULT_INJECTION_STACKTRACE_FILTER -e DETECT_HUNG_TASK \
  -d DEBUG_OBJECTS \
  -d DEBUG_INFO_DWARF5 -d DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT -e DEBUG_INFO_NONE -d DEBUG_INFO_BTF \
  -d MODULE_SIG_FORCE \
  --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS "" \
  --set-str LOCALVERSION "" -d LOCALVERSION_AUTO
make -s olddefconfig
for o in DEBUG_KMEMLEAK PROVE_LOCKING DEBUG_ATOMIC_SLEEP KASAN DMA_API_DEBUG \
  UBSAN UBSAN_BOUNDS UBSAN_SHIFT FAULT_INJECTION FAILSLAB FAIL_PAGE_ALLOC \
  FAULT_INJECTION_DEBUG_FS FAULT_INJECTION_STACKTRACE_FILTER DETECT_HUNG_TASK; do
  grep -q "^CONFIG_$o=y" .config || { echo "config: $o not enabled" >&2; exit 1; }
done
for o in UBSAN_ALIGNMENT UBSAN_TRAP; do
  ! grep -q "^CONFIG_$o=y" .config || { echo "config: $o enabled" >&2; exit 1; }
done
for o in VIDEO_DEV VIDEOBUF2_CORE VIDEOBUF2_V4L2 VIDEOBUF2_MEMOPS; do
  grep -q "^CONFIG_$o=[ym]" .config || { echo "config: $o not enabled" >&2; exit 1; }
done
make -s -j"$(nproc)" bindeb-pkg LOCALVERSION="-$SUFFIX" >/dev/null
cd ..
fi  # INSTALL != only
krel=$(make -s --no-print-directory -C "$src" kernelrelease LOCALVERSION="-$SUFFIX")
# the newest build only (bindeb-pkg numbers each one: _6.8.12-N)
debs="$(ls -v linux-image-"$krel"_*.deb | tail -1) $(ls -v linux-headers-"$krel"_*.deb | tail -1)"
echo "packages: $debs"
if [ "$INSTALL" = 0 ]; then
  echo "built $krel (not installed: INSTALL=0)"
  exit 0
fi
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
