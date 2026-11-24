#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M2: unbind the driver while an application streams with mapped buffers.
# The stream must stop (the application sees errors and exits), the device
# must unbind within 5 s, the driver state must stay valid until the
# application closes its file (refcounted), and a rebind must probe and
# stream again. The kernel log is checked as for every case; on the debug
# kernel kmemleak and DMA-API debug check that nothing leaked.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

drv=/sys/bus/pci/drivers/$GC573_MOD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cap=$(gc573_cap_build "$tmp") || fail "cannot build gc573-cap"

gc573_load || fail "insmod failed"
dev=$(gc573_video_dev) || { gc573_unload; fail "no video node"; }
"$cap" -d "$dev" -f NV12 -b 4 -n 100000 -p > "$tmp/out" 2>&1 &
pid=$!
sleep 1
kill -0 "$pid" 2>/dev/null || { cat "$tmp/out"; gc573_unload; fail "capture did not run"; }

t0=$(date +%s%N)
timeout 5 sh -c "echo $GC573_BDF > $drv/unbind"
urc=$?
t1=$(date +%s%N)
echo "unbind while streaming: exit $urc after $(( (t1 - t0) / 1000000 )) ms"
for _ in $(seq 50); do
	kill -0 "$pid" 2>/dev/null || break
	sleep 0.1
done
if kill -0 "$pid" 2>/dev/null; then
	kill "$pid"
	gc573_unload
	fail "capture still running 5 s after unbind"
fi
wait "$pid"
echo "capture exited with status $? (expected nonzero: device gone)"
sed 's/^/  /' "$tmp/out" | tail -4
[ "$urc" = 0 ] || { gc573_unload; fail "unbind failed or hung"; }
gc573_bound && { gc573_unload; fail "still bound after unbind"; }

echo "$GC573_BDF" > "$drv/bind" || { gc573_unload; fail "rebind failed"; }
gc573_bound || { gc573_unload; fail "not bound after rebind"; }
dev=$(gc573_video_dev) || { gc573_unload; fail "no video node after rebind"; }
"$cap" -d "$dev" -f YUYV -b 4 -n 30 -p 2>&1 | grep -E '^(RESULT|FAIL)' |
	sed 's/^/  /'
rc=${PIPESTATUS[0]}
gc573_unload || fail "rmmod failed"
[ "$rc" = 0 ] || fail "capture after rebind: exit $rc"
echo "rebind: probe and capture OK"
