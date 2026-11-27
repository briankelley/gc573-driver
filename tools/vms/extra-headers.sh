#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Header-only kernels for the regression matrix. matrix-build.sh and install-test.sh build
# against every /lib/modules/*/build, so the headers of a kernel a VM does not run add that
# kernel to the matrix: here the ones where stable or distro backports change what
# src/compat.h gets (Kbuild's header feature probes). Installed alongside the VM's own
# kernels, never in place of one, and never booted. Idempotent.
#   gc573-mint223     Ubuntu 24.04's 6.17 HWE: linux-headers-6.17.0-14-generic from the
#                     noble archive, the one 6.17 build made with the VM's gcc-13
#                     (13.3.0-6ubuntu2~24.04, which its own 6.14.0-37 needs too). Every
#                     later one was built with ~24.04.1, and kbuild's "the compiler
#                     differs" warning fails the matrix.
#   gc573-ubuntu2604  6.18.y LTS: kernel.ubuntu.com mainline v6.18.65, built in a 26.04
#                     chroot with the VM's gcc-15. Its amd64/CHECKSUMS must carry a good
#                     signature by the Kernel PPA key 60AA7B6F30434AE68E569963E50C6A0917C622B0
#                     (registered to Launchpad's ~kernel-ppa; fetched by that fingerprint
#                     from keyserver.ubuntu.com into a throwaway keyring), and both header
#                     debs must match their sha256 there.
# Then per kernel: build/Makefile and Module.symvers there, and the compiler the Makefile
# picks (the one CONFIG_CC_VERSION_TEXT names) prints that same text.
# Starts shut-off VMs and powers them off afterwards.
# Usage: tools/vms/extra-headers.sh [VM...]   (default: both)
# Needs: sudo (virsh; SUDO_ASKPASS without a tty), ssh aliases = VM names.
set -euo pipefail

VMS=("$@")
[ ${#VMS[@]} -gt 0 ] || VMS=(gc573-mint223 gc573-ubuntu2604)
for vm in "${VMS[@]}"; do
  case $vm in gc573-mint223|gc573-ubuntu2604) ;; *) echo "no extra headers for $vm" >&2; exit 2 ;; esac
done
sudo -n true 2>/dev/null || sudo -v || { echo "sudo: no credential" >&2; exit 2; }
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5)

# Runs inside the VM. Arg: ubuntu | mainline. Prints RESULT lines.
remote() {
  cat <<'EOS'
set -uo pipefail
res() { printf 'RESULT\t%s\t%s\t%s\n' "$1" "$2" "$3"; }
installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'; }
check() {
  local k=$1 b=/lib/modules/$1/build want cc got=
  want=$(sed -n 's/^CONFIG_CC_VERSION_TEXT="\(.*\)"$/\1/p' "$b/.config" 2>/dev/null)
  cc=${want%% *}
  command -v "$cc" > /dev/null 2>&1 && got=$("$cc" --version | head -1)
  if [ ! -e "$b/Makefile" ] || [ ! -s "$b/Module.symvers" ]; then
    res "$k" FAIL "no build/Makefile or Module.symvers"
  elif [ -z "$want" ] || [ "$got" != "$want" ]; then
    res "$k" FAIL "the compiler differs: kernel '$want', here '${got:-no $cc}'"
  else res "$k" PASS "headers with Module.symvers; $want"; fi
}
case $1 in
ubuntu)
  k=6.17.0-14-generic
  if ! installed "linux-headers-$k"; then
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      "linux-headers-$k" || { res "$k" FAIL "apt-get install"; exit 0; }
  fi
  check "$k" ;;
mainline)
  ver=6.18.65 abi=061865 stamp=202611231455 key=60AA7B6F30434AE68E569963E50C6A0917C622B0
  k=$ver-$abi-generic
  debs=("linux-headers-$ver-${abi}_$ver-$abi.${stamp}_all.deb"
        "linux-headers-${k}_$ver-$abi.${stamp}_amd64.deb")
  if ! installed "linux-headers-$k"; then
    d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
    u=https://kernel.ubuntu.com/mainline/v$ver/amd64
    for f in CHECKSUMS CHECKSUMS.gpg "${debs[@]}"; do
      curl -sSfL --max-time 600 -o "$d/$f" "$u/$f" || { res "$k" FAIL "download $f"; exit 0; }
    done
    export GNUPGHOME=$d/gnupg
    mkdir -m 700 "$GNUPGHOME"
    curl -sSfL --max-time 60 -o "$d/key.asc" \
      "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x$key" &&
      gpg --batch -q --import "$d/key.asc" 2>/dev/null
    st=$(gpg --batch --status-fd 1 --verify "$d/CHECKSUMS.gpg" "$d/CHECKSUMS" 2>/dev/null)
    if ! grep -q '^\[GNUPG:\] GOODSIG ' <<< "$st" ||
       ! grep -q "^\[GNUPG:\] VALIDSIG .* $key\$" <<< "$st"; then
      res "$k" FAIL "CHECKSUMS: no good signature by $key"; exit 0
    fi
    sed -n '/Checksums-Sha256/,$p' "$d/CHECKSUMS" | grep -F -e "${debs[0]}" -e "${debs[1]}" > "$d/sums"
    if [ "$(wc -l < "$d/sums")" != 2 ] || ! (cd "$d" && sha256sum -c sums); then
      res "$k" FAIL "sha256 of the header debs"; exit 0
    fi
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      "${debs[@]/#/$d/}" || { res "$k" FAIL "apt-get install"; exit 0; }
  fi
  check "$k" ;;
esac
EOS
}

rc=0
for vm in "${VMS[@]}"; do
  case $vm in gc573-mint223) kind=ubuntu ;; *) kind=mainline ;; esac
  started=0
  if [ "$(sudo virsh domstate "$vm")" != running ]; then
    sudo virsh start "$vm" > /dev/null; started=1
  fi
  for i in $(seq 1 60); do "${SSH[@]}" "$vm" true 2>/dev/null && break; sleep 4; done
  out=$("${SSH[@]}" "$vm" bash -s -- "$kind" < <(remote) 2>&1) || true
  echo "$out"
  grep -q -P '^RESULT\t[^\t]+\tPASS\t' <<< "$out" || rc=1
  if [ $started = 1 ]; then
    "${SSH[@]}" "$vm" sudo poweroff > /dev/null 2>&1 || true
    for i in $(seq 1 45); do [ "$(sudo virsh domstate "$vm")" = "shut off" ] && break; sleep 4; done
  fi
done
exit $rc
