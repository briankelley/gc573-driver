#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# dkms.conf builds gc573.ko for the running kernel: dkms add + build of a copy
# of the sources under a throwaway package name (never installed, so nothing
# can autoload it), then dkms remove. DKMS passes KERNELRELEASE on the make
# command line; this case catches a build that only works without DKMS.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

command -v dkms > /dev/null || skip "dkms not installed"

top=$(cd "$GC573_TESTS/.." && pwd)
pkg=gc573-testpkg
ver=0.0.$(date +%s)
src=/usr/src/$pkg-$ver
krel=$(uname -r)

cleanup() {
	dkms remove -m "$pkg" -v "$ver" --all > /dev/null 2>&1
	rm -rf "$src"
}
trap cleanup EXIT

mkdir -p "$src/src"
cp "$top/dkms.conf" "$top/Makefile" "$src/"
[ -f "$top/Kbuild" ] && cp "$top/Kbuild" "$src/"
cp "$top"/src/*.[ch] "$src/src/"
sed -i -e "s/^PACKAGE_NAME=.*/PACKAGE_NAME=\"$pkg\"/" \
	-e "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION=\"$ver\"/" "$src/dkms.conf"

dkms add -m "$pkg" -v "$ver" > /dev/null || fail "dkms add"
if ! out=$(dkms build -m "$pkg" -v "$ver" -k "$krel" 2>&1); then
	echo "$out"
	cat "/var/lib/dkms/$pkg/$ver/build/make.log" 2>/dev/null
	fail "dkms build for $krel"
fi
ko=$(find "/var/lib/dkms/$pkg/$ver/$krel" -name 'gc573.ko*' | head -n 1)
[ -n "$ko" ] || fail "dkms build produced no gc573.ko"
echo "$(dkms --version): built ${ko##*/} for $krel"
