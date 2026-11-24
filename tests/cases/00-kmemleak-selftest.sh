#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Harness self-test: the suite's kmemleak check must report a known leak.
# Builds tests/kmemleak-canary (8 x 128-byte allocations filled with 0xa5,
# leaked at load), loads and unloads it, runs the same report step as run.sh
# (kml_report) and expects the canary objects; then forgets them (kml_reset)
# so the suite-wide kmemleak result covers only the cases after this one.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

kml_available || skip "kmemleak not available on this kernel"

build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
cp "$GC573_TESTS/kmemleak-canary/Kbuild" \
	"$GC573_TESTS/kmemleak-canary/gc573_kmemleak_canary.c" "$build/"
if ! make -C "/lib/modules/$(uname -r)/build" M="$build" modules \
	> "$build/make.log" 2>&1; then
	cat "$build/make.log"
	fail "canary build"
fi

kml_reset
insmod "$build/gc573_kmemleak_canary.ko" || fail "canary insmod"
rmmod gc573_kmemleak_canary || fail "canary rmmod"
report=$(kml_report)
kml_reset

# each reported object prints its first 32 bytes as two 16-byte hex lines
lines=$(echo "$report" | grep -c '\(a5 \)\{15\}a5')
echo "kmemleak reported $(echo "$report" | grep -c '^unreferenced object')" \
	"object(s), $((lines / 2)) with the canary's 0xa5 fill (8 leaked)"
[ "$lines" -ge 2 ] || fail "kmemleak did not report the canary leak"
