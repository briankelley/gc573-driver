#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Test tools/install.sh and tools/uninstall.sh at a git ref on the regression
# matrix VMs (no card there). Per VM, one at a time:
#   crc-*            tests/card-release-check.sh: the scripts' holder scan and
#                    dead-card check, offline (its own processes, a made-up
#                    sysfs)
#   headers-missing  the running kernel's build link hidden: install.sh stops
#                    with the package to install, nothing installed
#   dkms-missing     dkms not on PATH: install.sh stops with the package to
#                    install (SKIP where dkms is in /usr/bin)
#   install          install.sh: DKMS builds and installs gc573 for every
#                    kernel with headers; no card, so nothing loads
#   alias            the card's modalias resolves to the installed module
#   autoinstall      Debian family with a second kernel with headers: gc573
#                    removed for it, then the distribution's kernel hook
#                    (/etc/kernel/postinst.d/dkms) builds it again (AUTOINSTALL)
#   reboot           after a reboot gc573 is not loaded (no device matches)
#   modprobe         modprobe gc573 loads it by hand (no device bound) and
#                    modprobe -r unloads it, kernel log clean
#   uninstall        uninstall.sh: no gc573 in DKMS, under /lib/modules or in
#                    /usr/src; the alias resolves to nothing
# Starts shut-off VMs and powers them off afterwards. Never gc573-dev or
# gc573-ref. Logs: tests/logs/install/<UTC>-<sha>/<vm>.log + summary.tsv
# Usage: tools/vms/install-test.sh [-r REF] [VM...]
# Needs: sudo (virsh; SUDO_ASKPASS without a tty), ssh aliases = VM names.
set -euo pipefail

REF=HEAD VMS=()
while [ $# -gt 0 ]; do
  case $1 in
    -r) REF=$2; shift 2 ;;
    -h|--help) sed -n '3,26p' "$0"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) VMS+=("$1"); shift ;;
  esac
done
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
sha=$(git -C "$root" rev-parse --short=12 "$REF^{commit}")
sudo -n true 2>/dev/null || sudo -v || { echo "sudo: no credential" >&2; exit 2; }
if [ ${#VMS[@]} -eq 0 ]; then
  mapfile -t VMS < <(sudo virsh list --all --name | grep '^gc573-' | grep -vx -e gc573-ref -e gc573-dev)
fi
for vm in "${VMS[@]}"; do
  case $vm in gc573-dev|gc573-ref) echo "refusing $vm" >&2; exit 2 ;; esac
done
out=$root/tests/logs/install/$(date -u +%Y%m%dT%H%M%SZ)-$sha
mkdir -p "$out"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5)

# Inside the VM, before the reboot
phase1() {
  cat <<'EOS'
set -uo pipefail
cd ~/gc573-install/gc573
ALIAS=pci:v00001461d00000054sv00001461sd00005730bc04sc00i00
. /etc/os-release
echo "distro: $PRETTY_NAME"; echo "running: $(uname -r)"
krel=$(uname -r)
ver=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' dkms.conf)
kernels=()
for b in /lib/modules/*/build; do [ -e "$b/Makefile" ] && kernels+=("$(basename "$(dirname "$b")")"); done
echo "kernels with headers: ${kernels[*]}"
res() { printf 'RESULT\t%s\t%s\t%s\n' "$1" "$2" "$3"; }
resolve() { modprobe -n -v "$ALIAS" 2>/dev/null | grep -o '[^ ]*gc573\.ko[^ ]*' | tail -1; }
sudo bash tools/uninstall.sh > /dev/null 2>&1 || true

echo "=== card-release-check"
sudo bash tests/card-release-check.sh

echo "=== headers-missing"
b=/lib/modules/$krel/build
o=$( (trap 'sudo mv "$b.off-test" "$b"' EXIT; sudo mv "$b" "$b.off-test" && sudo bash tools/install.sh) 2>&1); rc=$?
echo "$o"
if [ $rc -ne 0 ] && grep -q 'no headers for the running kernel' <<< "$o" && [ -e "$b/Makefile" ] &&
   ! sudo dkms status 2>/dev/null | grep -q gc573; then
  res headers-missing PASS "exit $rc; $(grep -o 'Install them with: [^,]*' <<< "$o" | head -1); nothing installed"
else res headers-missing FAIL "exit $rc"; fi

echo "=== dkms-missing"
if [ -n "$(sudo env PATH=/usr/bin:/bin bash -c 'command -v dkms' 2>/dev/null)" ]; then
  res dkms-missing SKIP "dkms is in /usr/bin here"
else
  o=$(sudo env PATH=/usr/bin:/bin bash tools/install.sh 2>&1); rc=$?
  echo "$o"
  if [ $rc -ne 0 ] && grep -q 'dkms is not installed' <<< "$o"; then
    res dkms-missing PASS "exit $rc; $(grep -o 'Install it with: [^(]*' <<< "$o" | head -1)"
  else res dkms-missing FAIL "exit $rc"; fi
fi

echo "=== install"
o=$(sudo bash tools/install.sh 2>&1); rc=$?
echo "$o"
st=$(sudo dkms status 2>/dev/null | grep gc573 || true)
echo "$st"
n=$(grep -c ': installed' <<< "$st" || true)
if [ $rc -eq 0 ] && grep -q 'no GC573 card found' <<< "$o" && [ "$n" -ge ${#kernels[@]} ]; then
  res install PASS "installed for $n of ${#kernels[@]} kernels with headers: $(modinfo -n gc573 2>/dev/null)"
else res install FAIL "exit $rc, installed for $n of ${#kernels[@]} kernels"; fi
if grep -qw '^gc573' /proc/modules; then res install-noload FAIL "gc573 loaded with no card"
else res install-noload PASS "not loaded: no card"; fi
a=$(resolve)
if [ -n "$a" ]; then res alias PASS "$ALIAS -> $a"; else res alias FAIL "the card's alias resolves to nothing"; fi

echo "=== autoinstall"
k2=
for k in "${kernels[@]}"; do [ "$k" != "$krel" ] && k2=$k; done
if [ -n "$k2" ] && [ -x /etc/kernel/postinst.d/dkms ]; then
  sudo dkms remove -m gc573 -v "$ver" -k "$k2" > /dev/null 2>&1
  before=$(sudo dkms status -k "$k2" 2>/dev/null | grep gc573 || true)
  sudo /etc/kernel/postinst.d/dkms "$k2" 2>&1 | tail -5
  after=$(sudo dkms status -k "$k2" 2>/dev/null | grep gc573 || true)
  echo "before: ${before:-none}"; echo "after: ${after:-none}"
  if ! grep -q ': installed' <<< "$before" && grep -q ': installed' <<< "$after"; then
    res autoinstall PASS "removed for $k2, then the kernel hook built and installed it: $after"
  else res autoinstall FAIL "for $k2: before '${before:-none}', after '${after:-none}'"; fi
else res autoinstall SKIP "no second kernel with headers, or no Debian-style kernel hook"; fi
cat /proc/sys/kernel/random/boot_id > /tmp/gc573-boot-id
EOS
}

# Inside the VM, after the reboot
phase2() {
  cat <<'EOS'
set -uo pipefail
cd ~/gc573-install/gc573
ALIAS=pci:v00001461d00000054sv00001461sd00005730bc04sc00i00
res() { printf 'RESULT\t%s\t%s\t%s\n' "$1" "$2" "$3"; }
resolve() { modprobe -n -v "$ALIAS" 2>/dev/null | grep -o '[^ ]*gc573\.ko[^ ]*' | tail -1; }
echo "running: $(uname -r)"
echo "=== reboot"
if [ "$(cat /proc/sys/kernel/random/boot_id)" = "$(cat /tmp/gc573-boot-id 2>/dev/null)" ]; then
  res reboot FAIL "no reboot happened"
elif grep -qw '^gc573' /proc/modules; then res reboot FAIL "gc573 loaded after boot with no card"
else res reboot PASS "not loaded after the boot: no device matches $ALIAS"; fi

echo "=== modprobe"
sudo dmesg -C
if sudo modprobe gc573; then
  lsmod | grep -w gc573
  sudo modprobe -r gc573; rc=$?
  if sudo dmesg | grep -v 'module verification failed' | grep -E -i 'WARNING:|BUG:|Oops|Call Trace'; then
    res modprobe FAIL "kernel log"
  elif [ $rc -ne 0 ] || grep -qw '^gc573' /proc/modules; then res modprobe FAIL "modprobe -r"
  else res modprobe PASS "loads by hand (no device bound) and unloads; kernel log clean"; fi
else res modprobe FAIL "modprobe gc573"; fi

echo "=== uninstall"
o=$(sudo bash tools/uninstall.sh 2>&1); rc=$?
echo "$o"
st=$(sudo dkms status 2>/dev/null | grep gc573 || true)
left=$(find /lib/modules -name 'gc573.ko*' 2>/dev/null || true)
srcs=$(ls -d /usr/src/gc573-* 2>/dev/null || true)
a=$(resolve)
if [ $rc -eq 0 ] && [ -z "$st" ] && [ -z "$left" ] && [ -z "$srcs" ] && [ -z "$a" ]; then
  res uninstall PASS "no gc573 in DKMS, under /lib/modules or /usr/src; the alias resolves to nothing"
else res uninstall FAIL "exit $rc; dkms '${st}'; files '${left}${srcs}'; alias '${a}'"; fi
rm -f /tmp/gc573-boot-id
EOS
}

wait_ssh() {
  local vm=$1 i
  for i in $(seq 1 60); do "${SSH[@]}" "$vm" true 2>/dev/null && return 0; sleep 4; done
  return 1
}

for vm in "${VMS[@]}"; do
  log=$out/$vm.log started=0
  {
    echo "vm: $vm  ref: $sha  date: $(date -u +%FT%TZ)"
    if [ "$(sudo virsh domstate "$vm")" != running ]; then
      sudo virsh start "$vm" > /dev/null; started=1
    fi
    if ! wait_ssh "$vm"; then
      printf 'RESULT\tssh\tFAIL\tno ssh after 240 s\n'
    else
      git -C "$root" archive --format=tar --prefix=gc573/ "$sha" |
        "${SSH[@]}" "$vm" 'rm -rf ~/gc573-install && mkdir -p ~/gc573-install && tar -x -C ~/gc573-install'
      "${SSH[@]}" "$vm" bash -s < <(phase1) 2>&1 || true
      # a reboot or shutdown turns a held card's bus mastering off (spec/pci.md)
      if ! "$root/tools/vms/card-idle.sh" "$vm"; then
        printf 'RESULT\treboot\tFAIL\tnot rebooted: card-idle.sh says the card in it is not idle\n'
      else
        "${SSH[@]}" "$vm" sudo reboot > /dev/null 2>&1 || true
        sleep 15
        if wait_ssh "$vm"; then
          "${SSH[@]}" "$vm" bash -s < <(phase2) 2>&1 || true
        else
          printf 'RESULT\treboot\tFAIL\tno ssh after the reboot\n'
        fi
      fi
      "${SSH[@]}" "$vm" 'rm -rf ~/gc573-install' > /dev/null 2>&1 || true
    fi
    if [ $started = 1 ] && ! "$root/tools/vms/card-idle.sh" "$vm"; then
      echo "note: $vm left running: card-idle.sh says the card in it is not idle"
    elif [ $started = 1 ]; then
      "${SSH[@]}" "$vm" sudo poweroff > /dev/null 2>&1 || true
      for i in $(seq 1 45); do [ "$(sudo virsh domstate "$vm")" = "shut off" ] && break; sleep 4; done
      [ "$(sudo virsh domstate "$vm")" = "shut off" ] || echo "note: $vm still running after poweroff"
    fi
  } > "$log" 2>&1
  grep -P '^RESULT\t' "$log" | cut -f2- | sed "s|^|$vm\t|"
done | tee "$out/summary.raw"
{
  printf 'vm\tdistro\tstep\tresult\tdetail\n'
  while IFS=$'\t' read -r vm step r detail; do
    d=$(sed -n 's/^distro: //p' "$out/$vm.log" | head -1)
    printf '%s\t%s\t%s\t%s\t%s\n' "$vm" "${d:-?}" "$step" "$r" "$detail"
  done < "$out/summary.raw"
} > "$out/summary.tsv"
rm -f "$out/summary.raw"
column -t -s $'\t' "$out/summary.tsv"
echo "logs: $out"
! grep -qP '\tFAIL\t' "$out/summary.tsv"
