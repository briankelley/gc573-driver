#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M3: the default EDID (spec/hdmi-chips.md "Default EDID"), read back with
# VIDIOC_G_EDID: two blocks, identity LNX 0x5730 "GC573 Linux", and
# edid-decode --check reports no errors and no warnings. VIDIOC_S_EDID: an
# image with another serial number reads back as set, 3 blocks give E2BIG
# (2 blocks max), the default image restores, and 0 blocks leave no EDID
# (G_EDID reports 0 blocks). The parser stays inside the CTA block: with
# byte 2 (first DTD offset) = 0xff and a 31-byte video data block whose
# header is the block's last content byte (126), ENUM_DV_TIMINGS lists the
# same timings as for the image with that header zeroed (the checksum
# byte, 127, would read as VIC 4, 720p60). SKIP without edid-decode.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

command -v edid-decode >/dev/null || skip "edid-decode not installed"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

gc573_load || fail "insmod failed"
dev=$(gc573_video_dev) || { gc573_unload; fail "no video node"; }
v4l2-ctl -d "$dev" --get-edid=file="$tmp/edid.bin",format=raw > "$tmp/get" 2>&1
rc=$?
if [ "$rc" = 0 ]; then
	# serial number 1, block 0 checksum fixed
	python3 - "$tmp/edid.bin" "$tmp/edid1.bin" "$tmp/edid3.bin" <<'EOF'
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
d[0x0c] = 0x01
d[0x7f] = -sum(d[0:0x7f]) & 0xff
open(sys.argv[2], 'wb').write(d)
open(sys.argv[3], 'wb').write(d + d[128:])
EOF
	v4l2-ctl -d "$dev" --set-edid=file="$tmp/edid1.bin",format=raw > "$tmp/set1" 2>&1
	set1=$?
	v4l2-ctl -d "$dev" --get-edid=file="$tmp/edid1r.bin",format=raw > /dev/null 2>&1
	v4l2-ctl -d "$dev" --set-edid=file="$tmp/edid3.bin",format=raw > "$tmp/set3" 2>&1
	# block 0 of the default; CTA: byte 2 = 0xff, video data blocks of
	# VIC 16 up to byte 125, then a 31-byte block header (or 0) at 126;
	# byte 3 makes the checksum (127) come out as 4
	python3 - "$tmp/edid.bin" "$tmp/svd.bin" "$tmp/svd0.bin" <<'EOF'
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
for out, last in ((sys.argv[2], 0x5f), (sys.argv[3], 0x00)):
    c = bytearray(128)
    c[0:3] = b'\x02\x03\xff'
    i = 4
    for n in (31, 31, 31, 25):
        c[i] = 0x40 | n
        c[i + 1:i + 1 + n] = bytes([16]) * n
        i += 1 + n
    c[126] = last
    c[127] = 4
    c[3] = -sum(c) & 0xff
    open(out, 'wb').write(d[:128] + c)
EOF
	v4l2-ctl -d "$dev" --set-edid=file="$tmp/svd0.bin",format=raw > /dev/null 2>&1
	v4l2-ctl -d "$dev" --list-dv-timings > "$tmp/enum0" 2>&1
	v4l2-ctl -d "$dev" --set-edid=file="$tmp/svd.bin",format=raw > "$tmp/setsvd" 2>&1
	setsvd=$?
	v4l2-ctl -d "$dev" --list-dv-timings > "$tmp/enum1" 2>&1
	v4l2-ctl -d "$dev" --set-edid=file="$tmp/edid.bin",format=raw > "$tmp/set0" 2>&1
	set0=$?
	v4l2-ctl -d "$dev" --get-edid=file="$tmp/edid0r.bin",format=raw > /dev/null 2>&1
	v4l2-ctl -d "$dev" --clear-edid=0 > "$tmp/clear" 2>&1
	clear=$?
	v4l2-ctl -d "$dev" --get-edid=format=hex > "$tmp/none" 2>&1
	v4l2-ctl -d "$dev" --set-edid=file="$tmp/edid.bin",format=raw > /dev/null 2>&1
fi
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

[ "$set1" = 0 ] || { cat "$tmp/set1"; fail "S_EDID failed"; }
cmp -s "$tmp/edid1.bin" "$tmp/edid1r.bin" || fail "S_EDID image does not read back"
echo "S_EDID serial 1: reads back"
grep -qi 'too big\|E2BIG\|argument list' "$tmp/set3" ||
	{ cat "$tmp/set3"; fail "3 blocks: no E2BIG"; }
echo "S_EDID 3 blocks: $(head -1 "$tmp/set3")"
[ "$setsvd" = 0 ] || { cat "$tmp/setsvd"; fail "S_EDID with CTA byte 2 = 0xff failed"; }
e0=$(grep -E 'Active (width|height)|Pixelclock' "$tmp/enum0")
e1=$(grep -E 'Active (width|height)|Pixelclock' "$tmp/enum1")
echo "CTA byte 2 = 0xff, 31-byte video data block at byte 126: $(grep -c 'Active width' "$tmp/enum1") timings enumerated, $(grep -c 'Active width' "$tmp/enum0") with the header zeroed"
[ -n "$e0" ] && [ "$e1" = "$e0" ] ||
	{ diff <(echo "$e0") <(echo "$e1") | sed 's/^/  /'; fail "SVDs read past the CTA block"; }
[ "$set0" = 0 ] && cmp -s "$tmp/edid.bin" "$tmp/edid0r.bin" ||
	fail "default EDID not restored"
echo "S_EDID default: restored"
[ "$clear" = 0 ] || { cat "$tmp/clear"; fail "S_EDID 0 blocks failed"; }
! grep -q '00 ff ff ff ff ff ff 00' "$tmp/none" ||
	{ cat "$tmp/none"; fail "EDID still present after 0 blocks"; }
echo "S_EDID 0 blocks: no EDID"
