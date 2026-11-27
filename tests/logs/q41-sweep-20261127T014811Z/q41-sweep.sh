#!/bin/bash
# Q41 sweep (spec session). Card on the host with gc573 bound, PC loopback
# source, nobody else using the card. Stage 1: one read per unread offset,
# each logged and fsync'd before the read. Stage 2: the same offsets sampled
# about every 1 ms across fresh locks in the same timings (an EDID serial
# change), (b) with no stream, (a) with a stream running free across it.
set -u
# Published copy: the private run directory is replaced by the script's own.
# It held bar0-sweep (bar0-sweep.c here), gc573-cap (tests/gc573-cap.c) and
# edid-variant.py (tools/roku/edid-variant.py).
H=$(dirname "$(readlink -f "$0")")
OUT=$H/q41-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$OUT"
V=/dev/v4l/by-path/pci-0000:07:00.0-video-index0
UNK="1014 1018 101c 1030 1034 1038 103c 1044 1048 104c 1050 1054 1058 106c 1070 1074 1078 1084 108c 1090 1094 1098 109c 10a4 10a8 10ac 10b0 10b4 10b8 10bc 10fc"
REF="1000 1004 1010 1080"
stage=${1:-all}
echo "out: $OUT"
if [ "$stage" = 1 ] || [ "$stage" = all ]; then
	echo "== stage 1 (once)"; sync
	sudo -A "$H/bar0-sweep" once "$OUT/stage1.log" $UNK | tee "$OUT/stage1.txt"
	[ "$stage" = 1 ] && exit 0
fi
v4l2-ctl -d "$V" --get-edid=file="$OUT/default.bin",format=raw > /dev/null || exit 1
python3 -I "$H/edid-variant.py" "$OUT/default.bin" "$OUT/serial.bin" --serial 0x5731 > /dev/null || exit 1
next=serial
edid() { v4l2-ctl -d "$V" --set-edid=file="$OUT/$1.bin",format=raw > /dev/null; date -u +%T.%N | cut -c1-12; }
for i in 1 2 3; do
	echo "== stage 2b-$i: no stream, EDID $next"
	sudo -A "$H/bar0-sweep" watch 6 1000 $REF $UNK > "$OUT/b$i.txt" & s=$!
	sleep 0.5; t=$(edid $next); echo "  EDID set at $t"
	wait $s; [ $next = serial ] && next=default || next=serial; sleep 3
done
for i in 1 2 3; do
	echo "== stage 2a-$i: a stream running free across it, EDID $next"
	sudo -A "$H/gc573-cap" -d "$V" -f YUYV -b 4 -X 14 -A 7000 -F > "$OUT/a$i-cap.txt" 2>&1 & c=$!
	sleep 2
	sudo -A "$H/bar0-sweep" watch 8 1000 $REF $UNK > "$OUT/a$i.txt" & s=$!
	sleep 0.5; t=$(edid $next); echo "  EDID set at $t"
	wait $s; wait $c; [ $next = serial ] && next=default || next=serial; sleep 3
done
[ $next = default ] && edid default > /dev/null
echo "== done; EDID back to default"
