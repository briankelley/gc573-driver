#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M3: the default EDID (spec/hdmi-chips.md "Default EDID"), read back with
# VIDIOC_G_EDID: two blocks, identity LNX 0x5730 "GC573 Linux", and
# edid-decode --check reports no errors and no warnings. SKIP without
# edid-decode.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

command -v edid-decode >/dev/null || skip "edid-decode not installed"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

gc573_load || fail "insmod failed"
dev=$(gc573_video_dev) || { gc573_unload; fail "no video node"; }
v4l2-ctl -d "$dev" --get-edid=file="$tmp/edid.bin",format=raw > "$tmp/get" 2>&1
rc=$?
gc573_unload || fail "rmmod failed"
[ "$rc" = 0 ] || { cat "$tmp/get"; fail "G_EDID failed"; }

size=$(stat -c %s "$tmp/edid.bin")
echo "G_EDID: $size bytes"
od -An -tx1 -v "$tmp/edid.bin" | sed 's/^/  /'
[ "$size" = 256 ] || fail "expected 2 blocks"
edid-decode --check "$tmp/edid.bin" > "$tmp/decode" 2>&1
rc=$?
sed 's/^/  | /' "$tmp/decode"
grep -q "Manufacturer: LNX" "$tmp/decode" || fail "manufacturer"
grep -q "Model: 22320" "$tmp/decode" || fail "product code 0x5730"
grep -q "Display Product Name: 'GC573 Linux'" "$tmp/decode" || fail "name"
[ "$rc" = 0 ] || fail "edid-decode exit $rc"
grep -q '^EDID conformity: PASS' "$tmp/decode" || fail "conformity"
! grep -qi '^warnings:' "$tmp/decode" || fail "edid-decode warnings"
! grep -qi '^failures:' "$tmp/decode" || fail "edid-decode failures"
echo "edid-decode: PASS, no warnings"
