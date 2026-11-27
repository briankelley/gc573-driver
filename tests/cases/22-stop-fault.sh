#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Stops that fail (security review of a0adb1d, F4), forced with the test
# parameter exp_stop_fault, with no input (free-running):
# - STREAMOFF with neither INT bit 0 (bit 0) nor a domain reset (bit 1):
#   the driver cannot tell the video DMA stopped, so bus mastering must go
#   off (PCI_COMMAND bit 2) before the buffers go back, debugfs must say
#   dma_dead 1, and neither a video nor an audio stream may start again.
#   A rebind (probe) must bring the card back: bus mastering on, a
#   pattern-checked capture, buffer memory back to 0.
# - Unbind while video and audio stream, with the audio stop ignored
#   (bit 2) and no domain reset (bit 1): the teardown's stop finds DMA_RUN
#   still on and must turn bus mastering off before the DMA memory goes;
#   the unbind must finish, both programs must end, and a rebind must
#   bring the card back.
# The kernel log checks of tests/run.sh (KASAN, DMA-API debug, lockdep)
# cover the frees; the failures this case provokes on purpose are allowed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

param=/sys/module/$GC573_MOD/parameters/exp_stop_fault
drv=/sys/bus/pci/drivers/$GC573_MOD
work=$(mktemp -d)
cap=$(gc573_cap_build "$work") || fail "cannot build gc573-cap"
aud=$(gc573_aud_build "$work") || fail "cannot build gc573-aud"
pids=()

cleanup() {
	[ -w "$param" ] && echo 0 > "$param"
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	wait 2>/dev/null
	gc573_loaded && gc573_unload
	rm -rf "$work"
}

{
	echo 'video stop: timeout waiting for INT bit 0'
	echo 'video stop \(no INT bit 0, no reset of domain 0\) failed: bus mastering off'
	echo 'teardown stop failed'
	echo 'HDMI: .*failed: -19'
} >> "$GC573_KMSG_ALLOW"

# PCI_COMMAND bit 2, bus master enable
master_on() {
	local cmd
	cmd=$(od -An -tx2 -j4 -N2 "/sys/bus/pci/devices/$GC573_BDF/config" | tr -d ' ')
	[ $((0x$cmd & 4)) != 0 ]
}

# $1: pid, $2: seconds; the process has ended
ended() {
	local i
	for i in $(seq $(($2 * 10))); do
		kill -0 "$1" 2>/dev/null || return 0
		sleep 0.1
	done
	return 1
}

mem_zero() {
	local m
	m=$(grep '^mem (live' "$(gc573_debugfs)")
	echo "$m"
	[ -z "$(echo "${m#*:}" | tr ' ' '\n' | grep -E '^[0-9]+$' | grep -vx 0)" ]
}

# unbind (bounded), bind, wait for the video node, input off, smoke capture
rebind() {
	local i
	if gc573_bound; then
		timeout 30 sh -c "echo $GC573_BDF > $drv/unbind" || fail "unbind did not finish"
	fi
	echo "$GC573_BDF" > "$drv/bind" || fail "bind failed"
	for i in $(seq 100); do
		vdev=$(gc573_video_dev 2>/dev/null) && [ -c "$vdev" ] && break
		sleep 0.1
	done
	[ -c "$vdev" ] || fail "no video node after the bind"
	master_on || fail "bus mastering still off after the bind"
	gc573_input_off "$vdev"
	"$cap" -d "$vdev" -n 30 -p > "$work/smoke.log" 2>&1 ||
		{ cat "$work/smoke.log"; fail "capture after the bind failed"; }
	echo "rebound: bus mastering on, 30 frames pattern-checked"
}

gc573_load || fail "insmod failed"
trap cleanup EXIT
[ -w "$param" ] || fail "no exp_stop_fault parameter (a driver without the stop checks)"
vdev=$(gc573_video_dev) || fail "no video device"
gc573_input_off "$vdev"
master_on || fail "bus mastering off after the load"

echo "-- STREAMOFF with no INT bit 0 and no domain reset"
tag=$(kmsg_mark "stop-fault streamoff")
"$cap" -d "$vdev" -n 120 > "$work/cap1.log" 2>&1 &
pid=$!
sleep 0.5
echo 3 > "$param"
wait "$pid"
echo "capture: exit $? ($(tail -1 "$work/cap1.log"))"
echo 0 > "$param"
kmsg_since "$tag" | grep -E 'video stop|bus mastering' | sed 's/^/  | /'
kmsg_since "$tag" | grep -q 'video stop (no INT bit 0, no reset of domain 0) failed: bus mastering off' ||
	fail "no bus-mastering-off line for the failed stop"
! master_on || fail "bus mastering still on after the failed stop"
grep -q 'dma_dead 1' "$(gc573_debugfs)" || fail "debugfs does not say dma_dead 1"
if "$cap" -d "$vdev" -n 5 > "$work/cap2.log" 2>&1; then
	fail "a video stream started after the failed stop"
fi
echo "video after it: $(grep -m1 -iE 'streamon|error|fail' "$work/cap2.log" || tail -1 "$work/cap2.log")"
if "$aud" -t 1 > "$work/aud1.log" 2>&1; then
	fail "an audio stream started after the failed stop"
fi
echo "audio after it: $(tail -1 "$work/aud1.log")"
rebind
mem_zero || fail "buffer memory not back to 0"

echo "-- unbind while streaming, the audio stop ignored, no domain reset"
tag=$(kmsg_mark "stop-fault teardown")
"$cap" -d "$vdev" -n 1000000 > "$work/cap3.log" 2>&1 &
pids+=($!)
"$aud" -t 600 > "$work/aud2.log" 2>&1 &
pids+=($!)
sleep 2
for p in "${pids[@]}"; do
	kill -0 "$p" 2>/dev/null || fail "a stream ended before the unbind"
done
echo 6 > "$param"
timeout 60 sh -c "echo $GC573_BDF > $drv/unbind" || fail "unbind did not finish"
echo 0 > "$param"
for p in "${pids[@]}"; do
	ended "$p" 10 || { kill "$p"; fail "a stream program did not end after the unbind"; }
done
wait 2>/dev/null
pids=()
echo "capture: $(tail -1 "$work/cap3.log")"
echo "audio:   $(tail -1 "$work/aud2.log")"
kmsg_since "$tag" | grep -E 'teardown stop|bus mastering' | sed 's/^/  | /'
kmsg_since "$tag" | grep -q 'teardown stop failed: DMA still on' ||
	fail "the teardown stop did not see the audio DMA still on"
kmsg_since "$tag" | grep -q 'teardown stop failed: bus mastering off' ||
	fail "no bus-mastering-off line at the teardown"
rebind
mem_zero || fail "buffer memory not back to 0"
echo "both failed stops turned bus mastering off, and the card came back"
