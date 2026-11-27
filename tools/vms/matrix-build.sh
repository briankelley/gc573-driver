#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Build the driver at a git ref on the regression-matrix VMs, against every kernel
# that has headers installed in each VM. W=1; any warning counts as a failure.
# Optional: --load (insmod/rmmod of the running kernel's build; no card needed, so
# only module init/exit and symbol resolution are tested), --dkms (dkms add/build
# for every kernel with headers, then remove).
# Starts shut-off VMs and powers them off afterwards. Never touches the VM that
# holds the card unless it is named explicitly (and then never loads the module).
# Logs: tests/logs/matrix/<UTC>-<sha>/<vm>.log + summary.tsv
# Usage: tools/vms/matrix-build.sh [-r REF] [-j N] [--load] [--dkms] [VM...]
#   default VMs: every libvirt domain gc573-* except gc573-ref (vendor driver,
#   kernel 5.4 is outside the supported range) and gc573-dev (agent bring-up VM).
#   Those two are refused even when named: both claim the card when they start.
# Needs: sudo (virsh), ssh aliases = VM names (tools/vms/create.sh, mint.sh).
set -euo pipefail

REF=HEAD J=1 LOAD=0 DKMS=0 VMS=()
while [ $# -gt 0 ]; do
  case $1 in
    -r) REF=$2; shift 2 ;;
    -j) J=$2; shift 2 ;;
    --load) LOAD=1; shift ;;
    --dkms) DKMS=1; shift ;;
    -h|--help) sed -n '3,15p' "$0"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) VMS+=("$1"); shift ;;
  esac
done

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
sha=$(git -C "$root" rev-parse --short=12 "$REF^{commit}")
# sudo: cached credential, a tty prompt, or SUDO_ASKPASS (used automatically without a tty)
sudo -n true 2>/dev/null || sudo -v || { echo "sudo: no credential" >&2; exit 2; }
if [ ${#VMS[@]} -eq 0 ]; then
  mapfile -t VMS < <(sudo virsh list --all --name | grep '^gc573-' | grep -vx -e gc573-ref -e gc573-dev)
fi
for vm in "${VMS[@]}"; do
  case $vm in gc573-dev|gc573-ref) echo "refusing $vm (it claims the card at start; not a matrix VM)" >&2; exit 2 ;; esac
done
card=$("$root/tools/vms/card.sh" --where 2>/dev/null || true)
out=$root/tests/logs/matrix/$(date -u +%Y%m%dT%H%M%SZ)-$sha
mkdir -p "$out"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5)

# Runs inside the VM. Args: load(0/1) dkms(0/1). Prints RESULT lines.
remote() {
  cat <<'EOS'
set -uo pipefail
load=$1 dkms=$2
cd ~/gc573-matrix/gc573
. /etc/os-release
echo "distro: $PRETTY_NAME"; echo "running: $(uname -r)"; echo "cc: $(gcc --version | head -1)"
kernels=()
for b in /lib/modules/*/build; do [ -e "$b/Makefile" ] && kernels+=("$(basename "$(dirname "$b")")"); done
[ ${#kernels[@]} -gt 0 ] || echo "RESULT	-	build	FAIL	no kernel headers installed"
for k in "${kernels[@]}"; do
  echo "=== build $k"
  make -s clean KDIR=/lib/modules/$k/build >/dev/null 2>&1 || true
  make KDIR=/lib/modules/$k/build W=1 > build.log 2>&1; rc=$?
  cat build.log
  w=$(grep -c 'warning:' build.log || true)
  ko=$(find . -name gc573.ko -newer build.log -o -name gc573.ko -print 2>/dev/null | head -1)
  if [ $rc -ne 0 ]; then echo "RESULT	$k	build	FAIL	rc=$rc warnings=$w"
  elif [ "$w" -gt 0 ]; then echo "RESULT	$k	build	FAIL	warnings=$w"
  else echo "RESULT	$k	build	PASS	$(modinfo -F vermagic "$ko" 2>/dev/null | cut -d' ' -f1) dead_block=$(modinfo -F dead_block "$ko" 2>/dev/null)"; fi
  if [ "$load" = 1 ] && [ "$k" = "$(uname -r)" ] && [ $rc -eq 0 ]; then
    echo "=== load $k"
    deps=$(modinfo -F depends "$ko" | tr ',' ' ')
    [ -n "$deps" ] && sudo modprobe -a $deps
    sudo dmesg -C
    if msg=$(sudo insmod "$ko" 2>&1); then
      lsmod | grep -w gc573 || true
      sudo rmmod gc573
      # the unsigned-module taint line is expected
      if sudo dmesg | grep -v 'module verification failed' | grep -E -i 'WARNING:|BUG:|Oops|Call Trace|gc573.*(error|fail)'; then
        echo "RESULT	$k	load	FAIL	dmesg"
      else echo "RESULT	$k	load	PASS	init/exit (no card)"; fi
    elif echo "$msg" | grep -q -i 'key was rejected\|required key not available'; then
      echo "RESULT	$k	load	SKIP	secure boot rejects unsigned module"
    else echo "$msg"; echo "RESULT	$k	load	FAIL	insmod"; fi
  fi
done
if [ "$dkms" = 1 ]; then
  ver=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' dkms.conf)
  echo "=== dkms gc573/$ver"
  sudo dkms remove "gc573/$ver" --all >/dev/null 2>&1 || true
  sudo rm -rf "/usr/src/gc573-$ver"; sudo cp -r . "/usr/src/gc573-$ver"
  sudo dkms add "gc573/$ver" >/dev/null
  for k in "${kernels[@]}"; do
    if sudo dkms build "gc573/$ver" -k "$k" 2>&1 | tail -5; then
      echo "RESULT	$k	dkms	PASS	build"
    else
      sudo cat "/var/lib/dkms/gc573/$ver/build/make.log" 2>/dev/null | tail -30
      echo "RESULT	$k	dkms	FAIL	build"
    fi
  done
  sudo dkms remove "gc573/$ver" --all >/dev/null 2>&1 || true
  sudo rm -rf "/usr/src/gc573-$ver"
fi
EOS
}

wait_ssh() {
  local vm=$1 i
  for i in $(seq 1 60); do "${SSH[@]}" "$vm" true 2>/dev/null && return 0; sleep 4; done
  return 1
}

one() {
  local vm=$1 log=$out/$1.log started=0 load=$LOAD i
  [ "$vm" = "$card" ] && load=0
  {
    echo "vm: $vm  ref: $sha  date: $(date -u +%FT%TZ)"
    if [ "$(sudo virsh domstate "$vm")" != running ]; then
      sudo virsh start "$vm" >/dev/null; started=1
    fi
    if ! wait_ssh "$vm"; then
      echo "RESULT	-	ssh	FAIL	no ssh after 240 s"
    else
      git -C "$root" archive --format=tar --prefix=gc573/ "$sha" |
        "${SSH[@]}" "$vm" 'rm -rf ~/gc573-matrix && mkdir -p ~/gc573-matrix && tar -x -C ~/gc573-matrix'
      "${SSH[@]}" "$vm" bash -s -- "$load" "$DKMS" < <(remote) 2>&1 || true
    fi
    # a shutdown turns the bus mastering of a card the VM holds off (spec/pci.md)
    if [ $started = 1 ] && ! "$root/tools/vms/card-idle.sh" "$vm"; then
      echo "note: $vm left running: card-idle.sh says its card is not idle"
    elif [ $started = 1 ]; then
      "${SSH[@]}" "$vm" sudo poweroff >/dev/null 2>&1 || true
      for i in $(seq 1 45); do [ "$(sudo virsh domstate "$vm")" = "shut off" ] && break; sleep 4; done
      [ "$(sudo virsh domstate "$vm")" = "shut off" ] || { sudo virsh shutdown "$vm" >/dev/null 2>&1; echo "note: $vm still running after poweroff"; }
    fi
  } > "$log" 2>&1
}

for vm in "${VMS[@]}"; do
  while [ "$(jobs -rp | wc -l)" -ge "$J" ]; do wait -n || true; done
  one "$vm" &
done
wait

{
  printf 'vm\tdistro\tkernel\tstep\tresult\tdetail\n'
  for vm in "${VMS[@]}"; do
    d=$(sed -n 's/^distro: //p' "$out/$vm.log" | head -1)
    grep -P '^RESULT\t' "$out/$vm.log" | cut -f2- | sed "s|^|$vm\t${d:-?}\t|" ||
      printf '%s\t%s\t-\t-\tFAIL\tno results\n' "$vm" "${d:-?}"
  done
} > "$out/summary.tsv"
column -t -s $'\t' "$out/summary.tsv"
echo "logs: $out"
! grep -q -P '\tFAIL\t' "$out/summary.tsv"
