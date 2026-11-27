#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Surprise removal: the PCI device removed through sysfs while video and
# audio stream and other files of the card are held open, then a rescan
# brings it back; GC573_REMOVE_ITER (3) rounds. Each round:
# - the input off; gc573-cap streaming (NV12, 4 buffers, pattern check),
#   gc573-aud reading, and two holders: one with the video node open, one
#   with the ALSA control node open (the case of tools/uninstall.sh with a
#   mixer left open);
# - echo 1 > /sys/bus/pci/devices/BDF/remove returns within 20 s while the
#   holders still hold (the teardown must not wait for files to close),
#   and the device's sysfs directory is gone;
# - gc573-cap and gc573-aud exit within 10 s, with an error;
# - each holder then tries an ioctl on its file (VIDIOC_QUERYCAP,
#   SNDRV_CTL_IOCTL_CARD_INFO): ENODEV (or EIO), and closes it (the
#   driver's state lives until then);
# - echo 1 > /sys/bus/pci/rescan: the device back and bound within 10 s
#   with its video node and ALSA card; the input off; a capture and an
#   audio read pass; the driver's buffer memory (debugfs "mem") is 0.
# A removal that blocks fails the case: the holders are killed then, so
# that it can finish. The kernel log is checked as for every case
# (KASAN, lockdep, a hung task: hung_task_timeout_secs 30 for the case).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

ITER=${GC573_REMOVE_ITER:-3}
pdev=/sys/bus/pci/devices/$GC573_BDF
tmp=$(mktemp -d)
pids=()
hung0=$(cat /proc/sys/kernel/hung_task_timeout_secs)
cleanup() {
	local p
	for p in "${pids[@]}"; do
		kill "$p" 2>/dev/null
	done
	echo "$hung0" > /proc/sys/kernel/hung_task_timeout_secs
	rm -rf "$tmp"
}
trap cleanup EXIT
echo 30 > /proc/sys/kernel/hung_task_timeout_secs
command -v python3 >/dev/null || skip "python3 needed (the file holders)"
cap=$(gc573_cap_build "$tmp") || fail "cannot build gc573-cap"
aud=$(gc573_aud_build "$tmp") || fail "cannot build gc573-aud"

# A file holder: opens $1, says "held", waits for SIGUSR1, then one ioctl
# ($2: video, VIDIOC_QUERYCAP; ctl, SNDRV_CTL_IOCTL_CARD_INFO), prints its
# result and closes
cat > "$tmp/hold.py" <<'EOF'
import errno, fcntl, os, signal, sys
path, kind = sys.argv[1], sys.argv[2]
signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGUSR1})
fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
print("held", flush=True)
signal.sigwait({signal.SIGUSR1})
# _IOR('V', 0, struct v4l2_capability: 104), _IOR('U', 1, struct snd_ctl_card_info: 376)
req, size = (0x80685600, 104) if kind == "video" else (0x81785501, 376)
try:
    fcntl.ioctl(fd, req, bytearray(size))
    print("ioctl OK", flush=True)
except OSError as e:
    print("ioctl " + errno.errorcode.get(e.errno, str(e.errno)), flush=True)
os.close(fd)
print("closed", flush=True)
EOF

wait_for() {	# seconds condition...: poll until the condition holds
	local s=$1 i
	shift
	for i in $(seq $((s * 10))); do
		"$@" && return 0
		sleep 0.1
	done
	return 1
}
gone() { ! kill -0 "$1" 2>/dev/null; }
held() { grep -q '^held' "$1" 2>/dev/null; }
ready() { gc573_bound && gc573_video_dev > /dev/null && gc573_pcm_hw > /dev/null; }

gc573_load || fail "insmod failed"
ready || { gc573_unload; fail "not bound with a video node and an ALSA card"; }

for r in $(seq "$ITER"); do
	echo "round $r"
	dev=$(gc573_video_dev)
	pcm=$(gc573_pcm_hw)
	ctl=/dev/snd/controlC$(cat "$pdev"/sound/card*/number)
	gc573_input_off "$dev"
	"$cap" -d "$dev" -f NV12 -b 4 -n 100000 -p > "$tmp/cap" 2>&1 &
	pc=$!
	"$aud" -D "$pcm" -t 600 > "$tmp/aud" 2>&1 &
	pa=$!
	python3 "$tmp/hold.py" "$dev" video > "$tmp/hv" 2>&1 &
	hv=$!
	python3 "$tmp/hold.py" "$ctl" ctl > "$tmp/hc" 2>&1 &
	hc=$!
	pids=("$pc" "$pa" "$hv" "$hc")
	wait_for 5 held "$tmp/hv" && wait_for 5 held "$tmp/hc" ||
		{ cat "$tmp/hv" "$tmp/hc"; gc573_unload; fail "round $r: the holders did not open $dev and $ctl"; }
	sleep 2
	gone "$pc" && { cat "$tmp/cap"; gc573_unload; fail "round $r: the capture did not run"; }
	gone "$pa" && { cat "$tmp/aud"; gc573_unload; fail "round $r: the audio read did not run"; }

	t0=$(date +%s%N)
	sh -c "echo 1 > $pdev/remove" &
	pr=$!
	pids+=("$pr")
	if ! wait_for 20 gone "$pr"; then
		echo "the removal still runs after 20 s: the holders are killed"
		kill -9 "$hv" "$hc" "$pc" "$pa" 2>/dev/null
		wait_for 30 gone "$pr" ||
			fail "round $r: the removal still runs 30 s after the holders were killed"
		fail "round $r: the removal waited for the files held open"
	fi
	t1=$(date +%s%N)
	[ ! -e "$pdev" ] || fail "round $r: $pdev still there after the removal"
	wait_for 10 gone "$pc" ||
		{ kill -9 "$pc"; fail "round $r: the capture still runs 10 s after the removal"; }
	wait_for 10 gone "$pa" ||
		{ kill -9 "$pa"; fail "round $r: the audio read still runs 10 s after the removal"; }
	wait "$pc"
	rcc=$?
	wait "$pa"
	rca=$?
	echo "  removed in $(( (t1 - t0) / 1000000 )) ms; capture exit $rcc ($(grep -E '^(FAIL|RESULT)' "$tmp/cap" | head -1)), audio exit $rca ($(grep -E 'RESULT|rror' "$tmp/aud" | head -1))"
	[ "$rcc" != 0 ] || fail "round $r: the capture ended without an error"
	[ "$rca" != 0 ] || fail "round $r: the audio read ended without an error"

	kill -USR1 "$hv" "$hc"
	wait_for 5 gone "$hv" || fail "round $r: the video holder did not close"
	wait_for 5 gone "$hc" || fail "round $r: the control holder did not close"
	echo "  holders after the removal: video $(sed -n 's/^ioctl //p' "$tmp/hv"), control $(sed -n 's/^ioctl //p' "$tmp/hc"); both closed"
	grep -qE '^ioctl (ENODEV|EIO)$' "$tmp/hv" ||
		fail "round $r: VIDIOC_QUERYCAP on the removed device: $(grep '^ioctl' "$tmp/hv")"
	grep -qE '^ioctl (ENODEV|EIO)$' "$tmp/hc" ||
		fail "round $r: CARD_INFO on the removed card: $(grep '^ioctl' "$tmp/hc")"
	grep -q '^closed' "$tmp/hv" && grep -q '^closed' "$tmp/hc" ||
		fail "round $r: a holder did not close its file"
	pids=()

	echo 1 > /sys/bus/pci/rescan
	wait_for 10 ready ||
		fail "round $r: not bound with a video node and an ALSA card 10 s after the rescan"
	dev=$(gc573_video_dev)
	pcm=$(gc573_pcm_hw)
	gc573_input_off "$dev"
	out=$("$cap" -d "$dev" -f YUYV -b 4 -n 30 -p 2>&1) ||
		{ echo "$out" | tail -3; gc573_unload; fail "round $r: capture after the rescan failed"; }
	out=$("$aud" -D "$pcm" -t 1 2>&1) ||
		{ echo "$out" | tail -3; gc573_unload; fail "round $r: audio after the rescan failed"; }
	mem=$(sed -n 's/^mem (live, all cards): //p' "$(gc573_debugfs)")
	[ "$mem" = "bufs 0 pages 0 vmaps 0 dlists 0 dl_bytes 0" ] ||
		{ gc573_unload; fail "round $r: driver memory not back to 0: ${mem:-no mem line}"; }
	echo "  rescan: bound, capture and audio OK, driver memory 0"
done
gc573_unload || fail "rmmod failed"
echo "$ITER removals while streaming with files held: clean"
