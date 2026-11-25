#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M3 and M4 live-input checks with the PC loopback source (AGENTS.md "Live
# source"). Runs on the HOST: drives the GPU output cabled to HDMI IN
# (DVI-D-0) with tools/testsrc/show.sh, avsync.sh and xrandr, on that output
# only (the primary output is never touched), and runs the checks in the
# gc573-dev VM over ssh with tests/gc573-cap.c, gc573-aud.c (alsa-lib),
# live-compare.py and live-av.py. Build the module in the VM first
# (tools/vmbuild.sh); this script loads it from ~/$VMDIR.
#
# Usage: tests/live.sh [STEP...]          (default: all steps, in this order)
#   bringup   load; the output connects; its EDID (xrandr --verbose) equals
#             VIDIOC_G_EDID byte for byte, and edid-decode passes it
#   lock      1080p60 and 1080p59.94: QUERY_DV_TIMINGS CTA 1080p60 (with the
#             1000/1001 flag at 59.94) within 3 s of the mode switch;
#             POWER_PRESENT = 1; SOURCE_CHANGE on lock, loss and mode change
#   relock    GC573_RELOCKS (25) x 2 mode switches 1080p60 <-> 1080p59.94
#             with show.sh: each locks to the new rate within 3 s
#   capture   1080p60 and 1080p59.94, 6 formats x GC573_LIVE_FRAMES (600):
#             each format's last frame compared with pattern.py, all frames
#             identical (full-frame hash), no sequence gaps, G_PARM equal
#             to the DV timings' nominal interval (1/60 below 59.5 Hz: the
#             card delivers those at 60 Hz), mean interval within 0.1 % of
#             the interval G_PARM reports, first frame dropped
#   modes     every other mode the GPU offers for the output: timings and a
#             verified capture (GC573_MODE_FRAMES, 120, per format)
#   change    input change while streaming: SOURCE_CHANGE, no DMA outside
#             the queued images; to other timings a DQBUF error and a
#             restart at the new timings; 60 -> 59.94 Hz (same buffers) the
#             stream carries on; an application that never sets timings
#             gets the new ones once its queue is free
#   loss      output off and on, idle and while streaming: the stream
#             carries on, black while off, the pattern again after
#   colour    RGB limited range, YCbCr 4:4:4, YCbCr 4:2:2 (report only)
#   audio     avsync.sh on HDMI audio: 10 s capture, a burst a second,
#             left 1 kHz and right 2 kHz (channel order, rate), 48 kHz
#             against the clock, no gap, no overrun (live-av.py)
#   avsync    GC573_AV_SECS (600) of audio and video together: no overrun,
#             no gap, the driver's period counters clean, and the A/V
#             offset (flash frame vs burst onset) with its drift
#   audioloss one audio capture across 5 video stream start/stops, an input
#             loss while video streams, relock, video again, an idle loss
#             and relock: no overrun, never stalled, no DMA restart at the
#             video stops, no gap (the losses' pauses are filled), bursts
#             with the right channels after the last relock
#   obs       OBS (tests/obs-run.sh starts it in the VM, obs-check.py
#             drives it through obs-websocket): every pixel format OBS
#             offers for the device, a source screenshot against pattern.py
#   obsav     GC573_OBS_SECS (600) of OBS recording avsync.sh (V4L2 and
#             ALSA sources): A/V offset and drift measured in the file
#             (obs-av.py), OBS's frame counters, OBS's log clean
#   obschange source changes while OBS records: output off and on (OBS
#             live again by itself), a change to 720p (OBS's source stops at
#             other timings); after the recording the source reopened as a
#             user would (obs-check.py reopen) at 720p, and after a change to
#             1080p: the pattern at the new size
#   obspw     OBS with the card's audio through PipeWire, as on a desktop
#             ("Audio Input Capture (PulseAudio)"): the VM's udev rule that
#             keeps PipeWire off the card is lifted for the step and put
#             back; GC573_PW_SECS (120) recorded as in obsav (not in the
#             default steps)
#   obsws     OBS through obs-websocket from the host (tests/obs-events.py):
#             GetSourceScreenshot against the pattern and its time,
#             InputVolumeMeters against the bursts, a 60 s recording's
#             image and A/V offset (avsync.sh --pattern)
#   obsevents OBS's V4L2 source through each source change, unattended:
#             sleep and wake, 60 <-> 59.94, 1080p <-> 720p (reopened through
#             the websocket), colour format, EDID; time to the first good
#             frame (GC573_OBSEV_REPS, 2, rounds). Then 1080p <-> 720p
#             while OBS records, in Hybrid MP4 and (report only) in MKV
#   avchange  the driver's A/V offset across 3 colour-format changes (each a
#             stream restart) under one avsync.sh session: within 1 ms
#   obssoak   the event soak with OBS: GC573_OBSSOAK_SECS (7200) recorded, a
#             screenshot every 2 s, a change every GC573_OBSSOAK_EVERY (180)
#             s; memory, CPU, the recording (not in the default steps)
#   soak      GC573_SOAK_SECS (7200) of audio and video (1080p60 YUYV)
#             together with avsync.sh, as avsync, and every minute the
#             kernel's memory (MemAvailable, Slab, SUnreclaim) and the CPU
#             time of the capture and of the driver's IRQ thread: memory
#             stable, CPU use reported (not in the default steps)
#   unload    unload while streaming video and audio
#   reload    GC573_RELOADS (50) unload/load cycles with the source active
#   compliance  v4l2-compliance -s with the live input
# Prints RESULT lines and a SUMMARY; log: tests/logs/<UTC>_<kernel>_live.log.
# Event log: tests/logs/<UTC>_<kernel>_live-events.log, every action that
# changes the card's input or its streams (UTC, ms), and the lines of
# tools/testsrc/guard.py, which watches the run: a test window outside the
# output, or test audio on any sink but the NVIDIA HDMI one, stops it.
# Leaves the module loaded and the pattern off.
set -uo pipefail

VM=${VM:-gc573-dev}
VMDIR=${VMDIR:-gc573-driver}
OUT=${GC573_OUTPUT:-DVI-D-0}
FRAMES=${GC573_LIVE_FRAMES:-600}
MODE_FRAMES=${GC573_MODE_FRAMES:-120}
RELOADS=${GC573_RELOADS:-50}
RELOCKS=${GC573_RELOCKS:-25}
AV_SECS=${GC573_AV_SECS:-600}
OBS_SECS=${GC573_OBS_SECS:-600}
OBSEV_REPS=${GC573_OBSEV_REPS:-2}
OBS_BUFFERING=${GC573_OBS_BUFFERING:-1}
OBSSOAK_SECS=${GC573_OBSSOAK_SECS:-7200}
OBSSOAK_EVERY=${GC573_OBSSOAK_EVERY:-180}
SOAK_SECS=${GC573_SOAK_SECS:-7200}
PW_SECS=${GC573_PW_SECS:-120}
# tools/devvm: keeps PipeWire (ACP_IGNORE) and PulseAudio off the card
PW_RULE=/etc/udev/rules.d/90-gc573-pulse-ignore.rules
# obspw's WirePlumber rule (the desktop user's config, removed after it)
PW_WP=.config/wireplumber/main.lua.d/51-gc573-obspw.lua
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=/tmp/gc573-live		# work directory in the VM
SSHCTL=/tmp/gc573-live-ssh-$$
export DISPLAY=${DISPLAY:-:0} XAUTHORITY=${XAUTHORITY:-$HOME/.Xauthority}

npass=0 nfail=0 nskip=0 results=()
result() {
	local line
	line=$(printf 'RESULT %-26s %-4s %s' "$1" "$2" "${3:-}")
	echo "$line"
	results+=("$line")
	case $2 in
	PASS) npass=$((npass + 1)) ;;
	SKIP) nskip=$((nskip + 1)) ;;
	*) nfail=$((nfail + 1)) ;;
	esac
}
check() {	# name, condition result (0 = pass), detail
	if [ "$2" = 0 ]; then result "$1" PASS "$3"; else result "$1" FAIL "$3"; fi
}

# The input-changing actions go to the run's event log (UTC, ms; matched
# against the card's front LED): every VM command that starts a capture,
# loads or unloads the driver, sets the EDID or starts or stops OBS; host
# side, src_off, the colour changes and the test sources themselves
# (show.sh and avsync.sh log their own mode sets and players)
ev() { [ -z "${GC573_EVENT_LOG:-}" ] || echo "$(date -u +%FT%T.%3NZ) live $*" >> "$GC573_EVENT_LOG"; }
vm() {
	local what="" rc
	case "$*" in
	*gc573-cap\ *|*gc573-aud\ *) what="stream" ;;
	*rmmod\ gc573*) what="driver unload" ;;
	*insmod\ *|*modprobe\ gc573*) what="driver load" ;;
	*drivers/gc573/unbind*) what="driver unbind" ;;
	*drivers/gc573/bind*) what="driver bind" ;;
	*--set-edid*) what="edid set" ;;
	*obs-run.sh\ start*) what="obs start" ;;
	*obs-run.sh\ stop*) what="obs stop" ;;
	esac
	case $what in
	stream) ev "stream start: $(head -c 120 <<< "$*" | tr '\n\t' '  ')" ;;
	driver*|edid*)
		# a probe or an EDID change pulses HPD, the host's output can drop
		# its mode: no test player then (the guard would stop the run)
		"$ROOT/tools/testsrc/avsync.sh" --off
		"$ROOT/tools/testsrc/show.sh" --off
		ev "$what" ;;
	?*) ev "$what" ;;
	esac
	ssh -n -o BatchMode=yes -o ControlMaster=auto -o ControlPath="$SSHCTL" \
		-o ControlPersist=120 "$VM" "$@"
	rc=$?
	[ "$what" != stream ] || ev "stream stop (exit $rc)"
	return $rc
}
vdev="" dbgdir=""
find_vdev() {
	local bdf
	bdf=$(vm "basename \$(readlink -f /sys/bus/pci/drivers/gc573/0000:*)" 2>/dev/null)
	vdev=/dev/$(vm "ls /sys/bus/pci/drivers/gc573/$bdf/video4linux/ 2>/dev/null" | head -1)
	dbgdir=/sys/kernel/debug/gc573-$bdf
	[ "$vdev" != /dev/ ]
}
cap() { vm "sudo $W/gc573-cap -d $vdev -D $dbgdir/video $*"; }
query() { vm "v4l2-ctl -d $vdev --query-dv-timings" 2>&1; }
locked() { vm "v4l2-ctl -d $vdev --query-dv-timings >/dev/null 2>&1"; }
hdmi_dbg() { vm "sudo cat $dbgdir/hdmi"; }
aud_dbg() { vm "sudo cat $dbgdir/audio"; }
aud() { vm "sudo $W/gc573-aud -D $pcm $*"; }
pcm=hw:CARD=GC573,DEV=0

connected() { grep -q "^$OUT connected" <<< "$(xrandr --current)"; }
wait_connected() {	# seconds
	local i
	for i in $(seq $(($1 * 10))); do
		connected && return 0
		sleep 0.1
	done
	return 1
}
# show.sh and avsync.sh close every test player before they set a mode. The
# output goes off only after the players are closed too: the window manager
# moves the windows it manages from an output that loses its mode to the
# primary one (the players' windows are override-redirect and their watchdog
# closes them within 0.2 s, but they go first all the same)
src_on() { "$ROOT/tools/testsrc/show.sh" "$OUT" "$1" "$2" >/dev/null; }
src_off() {
	"$ROOT/tools/testsrc/avsync.sh" --off
	"$ROOT/tools/testsrc/show.sh" --off
	ev "output off $OUT"
	xrandr --output "$OUT" --off
}

# avsync.sh at 1080p60, then the IT6805 audio state ON and the FPGA
# measuring 48 kHz (AUDIO_SAMPLE_PERIOD reads all ones for another 120-140
# ms after a fresh start; the samples are zero until then). The output goes
# on first (show.sh): a disabled output has no valid ELD, and the HDMI audio
# port needs a moment after a mode change before it shows one.
av_on() {
	local i d
	wait_connected 15 || return 1
	src_on 1920x1080 60 || return 1
	for i in $(seq 30); do
		"$ROOT/tools/testsrc/avsync.sh" "$@" "$OUT" 1920x1080 60 >/dev/null 2>&1 &&
			break
		sleep 0.5
	done
	[ "$i" -lt 30 ] || return 1
	for i in $(seq 40); do
		d=$(aud_dbg)
		grep -q 'it6805 audio on' <<< "$d" && grep -q '(48000 Hz)' <<< "$d" &&
			return 0
		sleep 0.25
	done
	return 1
}
av_off() { "$ROOT/tools/testsrc/avsync.sh" --off; }

# After the steps: both test sources closed, and none of their ffplay
# processes left running (an ffplay stopped while it starts up can hang in
# its exit path, and --off would not know)
testsrc_check() {
	local i left
	"$ROOT/tools/testsrc/avsync.sh" --off
	"$ROOT/tools/testsrc/show.sh" --off
	for i in $(seq 30); do
		left=$(pgrep -a -x ffplay | awk '/-window_title gc573-/ { printf "%s ", $1 }')
		[ -z "$left" ] && break
		sleep 0.1
	done
	check testsrc-closed "$([ -z "$left" ]; echo $?)" "(ffplay of show.sh or avsync.sh still running: ${left:-none})"
}

# One counter from the driver's debugfs "audio" text $1, e.g. aud_stat "$d" late
aud_stat() { grep -o "\b$2 [0-9]*" <<< "$1" | head -1 | cut -d' ' -f2; }

# live-av.py's RESULT lines ($2) as RESULT $1-NAME, other lines indented
av_results() {
	local name st detail
	while read -r _ name st detail; do
		result "$1-$name" "$st" "$detail"
	done < <(grep '^RESULT' <<< "$2")
	grep -v '^RESULT' <<< "$2" | sed 's/^/  /'
}

# Seconds from now until QUERY_DV_TIMINGS succeeds (limit $1), or "none"
time_to_lock() {
	local t0 i
	t0=$(date +%s%N)
	for i in $(seq $(($1 * 20))); do
		if locked; then
			echo "$(((($(date +%s%N) - t0) / 1000000)))"
			return 0
		fi
		sleep 0.05
	done
	echo none
	return 1
}
wait_unlocked() {
	local i
	for i in $(seq 100); do
		locked || return 0
		sleep 0.1
	done
	return 1
}

# the in-tree modules it depends on first, as tests/lib.sh gc573_load does
# (after a boot nothing has loaded videodev and videobuf2 yet)
load() {
	vm "cd $VMDIR && { lsmod | grep -q '^gc573 ' || {
		deps=\$(modinfo -F depends ./gc573.ko | tr , ' ') &&
		{ [ -z \"\$deps\" ] || sudo modprobe -a \$deps; } &&
		sudo insmod ./gc573.ko; }; }" &&
		find_vdev
}
unload() { vm "sudo rmmod gc573"; }

setup() {
	vm "mkdir -p $W && gcc -O2 -Wall -o $W/gc573-cap $VMDIR/tests/gc573-cap.c &&
		gcc -O2 -Wall -o $W/gc573-aud $VMDIR/tests/gc573-aud.c -lasound -lm" ||
		return 1
	scp -q -o ControlPath="$SSHCTL" "$ROOT/tools/testsrc/pattern.py" \
		"$ROOT/tests/live-compare.py" "$ROOT/tests/live-av.py" \
		"$ROOT/tests/obsws.py" "$ROOT/tests/obs-check.py" \
		"$ROOT/tests/obs-av.py" "$ROOT/tests/obs-run.sh" "$ROOT/tests/obs-events.py" "$VM:$W/"
}

# The frame interval G_PARM must report for the timings in a gc573-cap
# LOCK line ($1): their nominal interval; 1/60 below 59.5 Hz, which the
# card delivers at 60 Hz (spec/video-pipeline.md "Delivery rate")
nominal_interval() {
	python3 - "$1" <<'EOF'
import math, re, sys
l = sys.argv[1]
kv = dict(re.findall(r'(\w+)=(\S+)', l))
w, h = map(int, re.search(r' (\d+)x(\d+)[pi] ', l).groups())
hf, hs, hb = map(int, kv['h'].split('/'))
vf, vs, vb = map(int, kv['v'].split('/'))
n = (w + hf + hs + hb) * (h + vf + vs + vb)
d = int(kv['pixelclock'])
fl = int(kv['flags'], 16)
if fl & 2 and fl & 4:	# CAN_REDUCE_FPS and REDUCED_FPS
    n, d = n * 1001, d * 1000
if d < 59.5 * n:
    n, d = 1, 60
g = math.gcd(n, d)
print(f"{n // g}/{d // g}")
EOF
}

# Capture fmts x n frames at the current input; compare the last frame of
# each with pattern.py; check identical frames, gaps, cadence and the
# dropped first frame. $1: tag, $2: frames, $3: expected WxH, $4: rate
live_capture() {
	local tag=$1 n=$2 size=$3 rate=$4 out lock w h fps enc f rc=0 line
	out=$(cap "-L 10 -f all -b 4 -n $n -o $W/$tag -F" 2>&1)
	echo "$out" | grep -E '^(LOCK|NOLOCK|RESULT|FAIL|SKIP)' | sed 's/^/  /'
	echo "$out" | "$ROOT/tests/frame-report.py" | sed 's/^/  /'
	lock=$(echo "$out" | grep '^LOCK ')
	[ -n "$lock" ] || { result "$tag" FAIL "(no lock)"; return 1; }
	w=$(echo "$lock" | sed -E 's/.* ([0-9]+)x([0-9]+)p .*/\1/')
	h=$(echo "$lock" | sed -E 's/.* ([0-9]+)x([0-9]+)p .*/\2/')
	fps=$(echo "$lock" | sed -E 's/.* fps=([0-9.]+) .*/\1/')
	check "$tag-timings" "$([ "${w}x$h" = "$size" ]; echo $?)" \
		"(${w}x$h at $fps Hz, expected $size at $rate)"
	# G_PARM reports the DV timings' nominal interval as an exact fraction
	# (frame size over pixel clock, x 1001/1000 with REDUCED_FPS)
	local tpf nom
	tpf=$(sed -nE 's/.* tpf=([0-9]+\/[0-9]+) .*/\1/p' <<< "$lock")
	nom=$(nominal_interval "$lock")
	check "$tag-interval" "$([ -n "$tpf" ] && [ "$tpf" = "$nom" ]; echo $?)" \
		"(G_PARM $tpf, nominal $nom)"
	enc=709
	[ "$h" -ge 720 ] || enc=601
	vm "[ -f $W/p-${w}x$h.png ] || python3 $W/pattern.py $W/p-${w}x$h.png $w $h >/dev/null"
	for f in YUYV UYVY NV12 YV12 BGR3 XR24; do
		line=$(echo "$out" | grep "^RESULT capture fmt=$f ")
		if [ -z "$line" ]; then
			grep -q "^SKIP capture fmt=$f" <<< "$out" &&
				result "$tag-$f" SKIP "(not offered at ${w}x$h)" ||
				{ result "$tag-$f" FAIL "(no capture)"; rc=1; }
			continue
		fi
		cmp=$(vm "python3 $W/live-compare.py $W/p-${w}x$h.png $W/$tag.$f $f $w $h $enc" 2>&1)
		local crc=$?
		echo "$cmp" | sed 's/^/    /'
		# every frame equal to the compared one (bit 0); cadence within
		# 0.1 % of the measured frame period (bit 1)
		local fr arc
		fr=$(awk -v fps="$fps" -v n="$n" '{
			for (i = 3; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
			want = 1000 / fps; dev = (v["ivl_ms_mean"] - want) / want
			printf "frames %s gaps %s err %s distinct %s; mean %.4f ms, expected %.4f, %+.4f %%, min %s max %s\n",
				v["frames"], v["seq_gaps"], v["err_flags"], v["distinct_frames"],
				v["ivl_ms_mean"], want, dev * 100, v["min"], v["max"]
			exit !(v["frames"] == n && v["seq_gaps"] == 0 && v["err_flags"] == 0 &&
			       v["distinct_frames"] == 1) + 2 * !(dev < 0.001 && dev > -0.001)
		}' <<< "$line")
		arc=$?
		echo "    $fr"
		check "$tag-$f" "$([ $crc = 0 ] && [ $((arc & 1)) = 0 ]; echo $?)" \
			"($(sed -n 's/^RESULT compare //p' <<< "$cmp" | sed 's/ out_of_limit=0//'); ${fr%%;*})"
		check "$tag-$f-cadence" "$((arc >> 1))" "(${fr#*; })"
		[ $crc = 0 ] && [ $arc = 0 ] || rc=1
	done
	# the driver drops the first frame of every stream (video-dma.md)
	local ncap nskip
	ncap=$(grep -c '^RESULT capture ' <<< "$out")
	nskip=$(grep -c 'stats: .* skipped 1 ' <<< "$out")
	check "$tag-first-frame" "$([ "$ncap" -gt 0 ] && [ "$nskip" = "$ncap" ]; echo $?)" \
		"(skipped 1 in $nskip of $ncap streams)"
	return $rc
}

# ---- steps ----

step_bringup() {
	local tag hx vx
	unload 2>/dev/null
	tag=$(date +%s%N)
	vm "echo 'gc573-live: $tag' | sudo tee /dev/kmsg >/dev/null"
	load || { result bringup-load FAIL; return; }
	vm "sudo dmesg | awk -v m='gc573-live: $tag' 'f; index(\$0, m) { f = 1 }'" |
		grep -E 'I2C bus 1|IT6805|splitter|HDMI|video device' | sed 's/^/  /'
	wait_connected 10
	check bringup-connected $? "($OUT $(xrandr --current | grep "^$OUT " | cut -d' ' -f2))"
	vm "v4l2-ctl -d $vdev --get-edid=file=$W/edid.bin,format=raw >/dev/null"
	vx=$(vm "od -An -tx1 -v $W/edid.bin" | tr -d ' \n')
	hx=$(xrandr --verbose --current | awk -v o="$OUT" '
		$1 == o { f = 1; next } f && /^[^ \t]/ { exit }
		f && /EDID:/ { e = 1; next } e && /^[ \t]+[0-9a-f]+$/ { printf "%s", $1; next }
		e { exit }')
	echo "  driver: $vx"
	echo "  host:   $hx"
	check bringup-edid-host "$([ -n "$hx" ] && [ "$hx" = "$vx" ]; echo $?)" \
		"($(( ${#hx} / 2 )) bytes on the host, $(( ${#vx} / 2 )) from G_EDID)"
	vm "edid-decode --check $W/edid.bin" > /tmp/gc573-live-decode.txt 2>&1
	check bringup-edid-decode "$(grep -q '^EDID conformity: PASS' /tmp/gc573-live-decode.txt &&
		! grep -qi '^warnings:' /tmp/gc573-live-decode.txt; echo $?)" \
		"($(grep 'conformity' /tmp/gc573-live-decode.txt))"
}

# SOURCE_CHANGE while $2 runs on the host; $1: tag
event_during() {
	local tag=$1 ev
	shift
	vm "timeout 20 v4l2-ctl -d $vdev --wait-for-event=source_change=0" \
		> /tmp/gc573-live-ev.txt 2>&1 &
	local p=$!
	sleep 1.5
	"$@" >/dev/null
	wait $p
	ev=$(tr '\n' ' ' < /tmp/gc573-live-ev.txt)
	check "$tag" "$(grep -q 'source_change' /tmp/gc573-live-ev.txt; echo $?)" "($ev)"
}

# QUERY_DV_TIMINGS output ($1) is CTA-861 VIC 16, 1920x1080p at 148.5 MHz
cta1080p60() {
	grep -q 'Active width: 1920' <<< "$1" &&
		grep -q 'Active height: 1080' <<< "$1" &&
		grep -q 'Frame format: progressive' <<< "$1" &&
		grep -q 'Pixelclock: 148500000 Hz' <<< "$1" &&
		grep -q 'CTA-861 VIC: 16' <<< "$1"
}

step_lock() {
	local t q t0
	src_on 1920x1080 60
	time_to_lock 10 >/dev/null
	src_off
	wait_unlocked
	t0=$(date +%s%N)
	src_on 1920x1080 60
	time_to_lock 10 >/dev/null
	t=$(( ($(date +%s%N) - t0) / 1000000 ))
	q=$(query)
	echo "$q" | sed 's/^/  /'
	check lock-1080p60 "$(cta1080p60 "$q" && ! grep -q 'framerate is reduced' <<< "$q" &&
		[ "$t" -le 3000 ]; echo $?)" "($t ms from output on)"
	t0=$(date +%s%N)
	src_on 1920x1080 59.94
	wait_unlocked
	time_to_lock 10 >/dev/null
	t=$(( ($(date +%s%N) - t0) / 1000000 ))
	q=$(query)
	echo "$q" | sed 's/^/  /'
	check lock-1080p59.94 "$(cta1080p60 "$q" && grep -q 'framerate is reduced by 1/1.001' <<< "$q" &&
		[ "$t" -le 3000 ]; echo $?)" "($t ms from the mode switch)"
	q=$(vm "v4l2-ctl -d $vdev --get-ctrl=power_present" 2>&1)
	check lock-power-present "$(grep -q 'power_present: 1' <<< "$q"; echo $?)" "($q)"
	event_during lock-event-mode-change src_on 1920x1080 60
	time_to_lock 10 >/dev/null
	event_during lock-event-loss src_off
	event_during lock-event-lock src_on 1920x1080 60
	time_to_lock 10 >/dev/null
	q=$(vm "v4l2-ctl -d $vdev --get-input; v4l2-ctl -d $vdev --list-inputs" 2>&1)
	echo "$q" | sed 's/^/  /'
}

# ms until QUERY_DV_TIMINGS reports CTA 1080p60 with ($1 = 1) or without
# ($1 = 0) the 1000/1001 flag; limit $2 s. Prints ms or "none".
time_to_rate() {
	local t0 i q
	t0=$(date +%s%N)
	for i in $(seq $(($2 * 10))); do
		q=$(vm "v4l2-ctl -d $vdev --query-dv-timings 2>/dev/null")
		if cta1080p60 "$q" &&
			[ "$(echo "$q" | grep -c 'framerate is reduced by')" = "$1" ]; then
			echo $((($(date +%s%N) - t0) / 1000000))
			return 0
		fi
		sleep 0.05
	done
	echo none
	return 1
}

step_relock() {
	local i r red t0 t ms n=0 bad=0 tmax=0 times=""
	for i in $(seq "$RELOCKS"); do
		for r in 59.94 60; do
			red=0
			[ "$r" = 59.94 ] && red=1
			t0=$(date +%s%N)
			src_on 1920x1080 "$r"
			t=$(time_to_rate "$red" 10)
			n=$((n + 1))
			if [ "$t" = none ]; then
				bad=$((bad + 1))
				echo "  switch $n to $r: no lock within 10 s"
				hdmi_dbg | sed 's/^/    /'
				src_off
				wait_unlocked
				continue
			fi
			ms=$((($(date +%s%N) - t0) / 1000000))
			times="$times $ms"
			[ "$ms" -gt "$tmax" ] && tmax=$ms
			[ "$ms" -le 3000 ] || bad=$((bad + 1))
		done
	done
	echo "  ms from the switch to the new rate:$times"
	check relock "$([ $bad = 0 ]; echo $?)" \
		"($((n - bad)) of $n switches locked within 3 s, slowest $tmax ms; $(hdmi_dbg | grep -oE '(level_changes|fpga_rejects) [0-9]+' | tr '\n' ' '))"
}

# Show the pattern in a mode and wait until the input has locked to it and
# the source has settled: 90 frames in a row identical and evenly spaced.
# show.sh's viewer appears a moment after the mode switch, and the GPU's
# output timing steps once when it goes full screen (one interval of
# 10-30 ms, at the content change, in every try), which the FPGA output
# follows; a capture across that step is not the driver's doing.
src_mode() {
	src_on "$1" "$2"
	sleep 1
	settle
}

settle() {
	local i
	time_to_lock 15 >/dev/null
	for i in $(seq 8); do
		cap "-f YUYV -b 4 -n 90 -F" 2>&1 | python3 -c '
import re, sys
fr = [m.groups() for m in (re.match(r"FRAME seq=(\d+) ts_ms=([\d.]+) sig=(\w+)", l)
                            for l in sys.stdin) if m]
iv = [float(b[1]) - float(a[1]) for a, b in zip(fr, fr[1:])]
med = sorted(iv)[len(iv) // 2] if iv else 0
ok = len(fr) == 90 and len({f[2] for f in fr}) == 1 and \
     all(abs(d - med) < 0.05 * med for d in iv)
sys.exit(0 if ok else 1)' && return 0
	done
	echo "  source not settled after 8 tries"
}

step_capture() {
	src_mode 1920x1080 60
	live_capture cap-1080p60 "$FRAMES" 1920x1080 60
	src_mode 1920x1080 59.94
	live_capture cap-1080p59.94 "$FRAMES" 1920x1080 59.94
}

step_modes() {
	local m r
	while read -r m r; do
		[ "$m" = 1920x1080 ] && { [ "$r" = 60.00 ] || [ "$r" = 59.94 ]; } && continue
		echo "== $m @ $r"
		src_mode "$m" "$r"
		live_capture "mode-${m}@$r" "$MODE_FRAMES" "$m" "$r"
	done < <(xrandr --current | awk -v o="$OUT" '$1 == o { f = 1; next }
		f && /^[^ ]/ { exit }
		f { for (i = 2; i <= NF; i++) { r = $i; gsub(/[*+]/, "", r); if (r != "") print $1, r } }')
	src_mode 1920x1080 60
}

# Stream (cap -X), then run the host action $4... after 4 s. $1: tag;
# $2: what the stream must do: "error" (DQBUF fails after the event: the
# input locked in other timings) or "continue" (no DQBUF error, frames
# after the last event: the driver restarted the stream); $3: more
# gc573-cap options: -r (restart at the new timings afterwards), -o FILE
# (keep the last frame), -A MS, -X SECS
change_while_streaming() {
	local tag=$1 want=$2 opts=$3 out line err after ok
	shift 3
	vm "sudo $W/gc573-cap -d $vdev -f YUYV -b 4 -n 60 -X 20 $opts -D $dbgdir/video" \
		> /tmp/gc573-live-x.txt 2>&1 &
	local p=$!
	sleep 4
	"$@" >/dev/null
	wait $p
	local rc=$?
	out=$(cat /tmp/gc573-live-x.txt)
	echo "$out" | grep -E '^(INFO change|RESULT|FAIL|LOCK|gc573-cap:)|stream:|stats:' | sed 's/^/  /'
	line=$(sed -n 's/^RESULT change //p' <<< "$out")
	err=$(grep -oE 'dqbuf_error_ms=-?[0-9]+' <<< "$line" | cut -d= -f2)
	after=$(grep -oE 'frames_after_last_event=[0-9]+' <<< "$line" | cut -d= -f2)
	case $want in
	error) ok=$([ "${err:--1}" -ge 0 ]; echo $?) ;;
	*) ok=$([ "${err:-0}" -lt 0 ] && [ "${after:-0}" -ge 60 ]; echo $?) ;;
	esac
	[ "$rc" = 0 ] || ok=1
	check "$tag" "$ok" "($want: $line$(grep -q -- -r <<< "$opts" && echo "; restart: $(echo "$out" | grep '^RESULT capture ' | grep -oE 'fmt=[^ ]+ [0-9x]+ frames=[0-9]+')"))"
}

# A frame gc573-cap -o kept ($2, YUYV 1920x1080) against pattern.py; $1: tag
frame_is_pattern() {
	local cmp
	vm "[ -f $W/p-1920x1080.png ] || python3 $W/pattern.py $W/p-1920x1080.png 1920 1080 >/dev/null"
	cmp=$(vm "python3 $W/live-compare.py $W/p-1920x1080.png $2 YUYV 1920 1080 709" 2>&1)
	check "$1" $? "($(sed -n 's/^RESULT compare //p' <<< "$cmp" | tr '\n' ' '))"
}

# Share of a YUYV frame ($1) that is limited-range black, word 0x80108010
frame_black() {
	vm "python3 -c 'import sys, numpy as np; a = np.fromfile(sys.argv[1], dtype=\"<u4\"); print(f\"{(a == 0x80108010).mean() * 100:.2f}\")' $1"
}

off_on() { src_off; sleep 4; src_on 1920x1080 60; }

step_change() {
	local out line
	src_on 1920x1080 60
	time_to_lock 10 >/dev/null
	change_while_streaming change-1080p60-to-720p60 error -r src_on 1280x720 60
	change_while_streaming change-720p60-to-1080p60 error -r src_on 1920x1080 60
	# the buffers still fit: the driver restarts the stream at 59.94 Hz
	change_while_streaming change-1080p60-to-p59.94 continue -r src_on 1920x1080 59.94
	# an application that never sets timings streams through a change to
	# 720p and keeps its buffers until after the lock (OBS): once its
	# queue is free the device has the new timings
	src_mode 1920x1080 60
	change_while_streaming change-to-720p-held error "-H 6" src_on 1280x720 60
	time_to_lock 10 >/dev/null
	out=$(cap "-f YUYV -b 4 -n 30" 2>&1)
	line=$(grep -E '^(RESULT capture|FAIL)|STREAMON' <<< "$out" | head -2 | tr '\n' ' ')
	check change-adopted "$(grep -q '^RESULT capture fmt=YUYV 1280x720 frames=30 ' <<< "$out"; echo $?)" \
		"(capture without setting timings: $line)"
	src_mode 1920x1080 60
}

step_loss() {
	local q out
	src_on 1920x1080 60
	time_to_lock 10 >/dev/null
	event_during loss-idle-event src_off
	q=$(query)
	echo "  query while off: $q" | head -3
	check loss-idle-query "$(grep -qiE 'link|lock' <<< "$q"; echo $?)" "($(echo "$q" | head -1))"
	q=$(vm "v4l2-ctl -d $vdev --list-inputs" 2>&1 | grep -i status)
	echo "  input:$q"
	# what the hardware delivers while unlocked: free-running frames
	out=$(cap "-f YUYV -b 4 -n 30 -o $W/unlocked" 2>&1)
	echo "$out" | grep -E '^(RESULT|FAIL)' | sed 's/^/  /'
	vm "od -An -tx1 -N 32 $W/unlocked.YUYV" | sed 's/^/  unlocked frame: /'
	check loss-unlocked-stream "$(grep -q '^RESULT capture' <<< "$out"; echo $?)" \
		"($(echo "$out" | grep -o 'ch0_top_word=[^ ]*'))"
	event_during loss-idle-return src_on 1920x1080 60
	t=$(time_to_lock 10)
	check loss-idle-relock $? "($t ms)"
	# live stream, then the output goes off: an event, and the stream
	# carries on free-running, black (spec/video-dma.md)
	change_while_streaming loss-streaming continue "-o $W/lost" src_off
	q=$(frame_black $W/lost.YUYV)
	check loss-streaming-black "$([ "$q" = 100.00 ]; echo $?)" "(last frame: $q % limited-range black)"
	# free-running stream (no input), then the output comes back: an event,
	# and the stream carries on live (same timings)
	wait_unlocked
	change_while_streaming loss-return-streaming continue "-o $W/back" src_on 1920x1080 60
	frame_is_pattern loss-return-pattern $W/back.YUYV
	# live stream through output off, 4 s, on (an application that ignores
	# the events, as OBS does, keeps getting frames)
	time_to_lock 10 >/dev/null
	change_while_streaming loss-off-on-streaming continue "-X 30 -A 12000 -o $W/offon" off_on
	frame_is_pattern loss-off-on-pattern $W/offon.YUYV
}

# The published colour format and range ($1: tag) follow the AVI InfoFrame
# as the splitter RX holds it (its own copy, RX bank 2 0x12-0x23): Y from
# PB1, RGB range from PB3 Q (0: full below VIC 2), YCbCr range from PB5 YQ
avi_check() {
	local d line pb1 pb3 vic pb5 y full got
	d=$(hdmi_dbg)
	line=$(grep '^splitter: avi ' <<< "$d")
	read -r _ _ _ _ _ pb1 _ pb3 vic pb5 _ <<< "$line"
	y=$(((0x$pb1 >> 5) & 3))
	if [ "$y" = 0 ]; then
		full=$(( ((0x$pb3 >> 2) & 3) == 2 || (((0x$pb3 >> 2) & 3) == 0 && 0x$vic < 2) ))
	else
		full=$(( (0x$pb5 >> 6) == 1 ))
	fi
	got=$(grep -oE 'colour [0-9] vic [0-9]+ full_range [01]' <<< "$d" |
		sed -E 's/ vic [0-9]+//')
	check "$1-avi" "$([ "$got" = "colour $y full_range $full" ]; echo $?)" \
		"(splitter AVI PB1 $pb1 PB3 $pb3 PB5 $pb5: colour $y full_range $full; published: $got)"
}

step_colour() {
	local cs cr name
	src_mode 1920x1080 60
	for cs_cr in "0 1 rgb-limited" "2 1 ycbcr444" "1 1 ycbcr422"; do
		set -- $cs_cr
		cs=$1 cr=$2 name=$3
		ev "colour ColorSpace=$cs ColorRange=$cr"
		nvidia-settings --no-write-config -a "[DPY:$OUT]/ColorSpace=$cs" \
			-a "[DPY:$OUT]/ColorRange=$cr" >/dev/null 2>&1
		sleep 2
		settle
		hdmi_dbg | grep -E '^(it6805: mode|splitter: avi|input:)' | sed 's/^/  /'
		avi_check "colour-$name"
		live_capture "colour-$name" 60 1920x1080 60
		result "colour-$name-note" SKIP "(report only, not gating)"
	done
	ev "colour ColorSpace=0 ColorRange=0"
	nvidia-settings --no-write-config -a "[DPY:$OUT]/ColorSpace=0" \
		-a "[DPY:$OUT]/ColorRange=0" >/dev/null 2>&1
	sleep 3
}

# M4: avsync.sh's bursts on the HDMI audio, 10 s
step_audio() {
	local out
	av_on || { result audio-source FAIL "(avsync.sh or the IT6805 audio state ON)"; av_off; return; }
	hdmi_dbg | grep -E '^it6805: (state|audio)' | sed 's/^/  /'
	aud "-t 10 -v -o $W/audio.raw" > /tmp/gc573-live-a.txt 2>&1
	check audio-capture $? "($(grep -E '^RESULT' /tmp/gc573-live-a.txt))"
	scp -q -o ControlPath="$SSHCTL" /tmp/gc573-live-a.txt "$VM:$W/audio.txt"
	out=$(vm "python3 $W/live-av.py $W/audio.txt $W/audio.raw --bursts")
	av_results audio "$out"
	aud_dbg | sed 's/^/  /'
	av_off
}

# M4: GC573_AV_SECS of audio and video together (gate: 10 min without an
# overrun or a gap, the A/V offset and drift over at least 5 min)
step_avsync() {
	local out d0 d1 n bad=""
	av_on || { result avsync-source FAIL "(avsync.sh or the IT6805 audio state ON)"; av_off; return; }
	# the GPU's output timing steps once when ffplay goes full screen (see
	# src_mode); settle() needs 90 identical frames, which avsync never has
	sleep 3
	d0=$(aud_dbg)
	vm "sudo $W/gc573-aud -D $pcm -t $AV_SECS -v -V $vdev -o $W/av.raw > $W/av.txt 2>&1"
	check avsync-capture $? "($(vm "grep -E '^(PARAMS|RESULT)' $W/av.txt" | tr '\n' ' '))"
	d1=$(aud_dbg)
	echo "$d1" | sed 's/^/  /'
	for n in late order bad_done stop_missing; do
		[ "$(aud_stat "$d0" $n)" = "$(aud_stat "$d1" $n)" ] ||
			bad+=" $n +$(( $(aud_stat "$d1" $n) - $(aud_stat "$d0" $n) ))"
	done
	check avsync-periods "$([ -z "$bad" ]; echo $?)" \
		"(driver: $(( $(aud_stat "$d1" periods) - $(aud_stat "$d0" periods) )) periods, $(( $(aud_stat "$d1" silent) - $(aud_stat "$d0" silent) )) silent, $(( $(aud_stat "$d1" pauses) - $(aud_stat "$d0" pauses) )) source pauses filled with $(( $(aud_stat "$d1" filled) - $(aud_stat "$d0" filled) )) frames${bad:-; none late or out of order})"
	hdmi_dbg | grep -E '^it6805: audio' | sed 's/^/  /'
	out=$(vm "python3 $W/live-av.py $W/av.txt $W/av.raw --min-secs $((AV_SECS * 9 / 10))")
	av_results avsync "$out"
	vm "rm -f $W/av.raw"
	av_off
}

# M4: one audio capture across video start/stop and input loss/relock
step_audioloss() {
	local p rc out d0 d1 i vrc=0 t0
	av_on || { result audioloss-source FAIL "(avsync.sh or the IT6805 audio state ON)"; av_off; return; }
	d0=$(aud_dbg)
	t0=$(date +%s)
	vm "sudo $W/gc573-aud -D $pcm -t 80 -v -o $W/aloss.raw > $W/aloss.txt 2>&1" &
	p=$!
	sleep 3
	for i in 1 2 3 4 5; do
		cap "-L 5 -f YUYV -b 4 -n 60" > /dev/null 2>&1 || vrc=1
		sleep 1
	done
	check audioloss-video "$vrc" "(5 video captures while audio runs)"
	# input loss while video streams (the stream goes on free-running), relock
	change_while_streaming audioloss-video-loss continue "" src_off
	sleep 3
	av_on
	check audioloss-relock $? "(avsync.sh again, IT6805 audio ON)"
	cap "-L 10 -f YUYV -b 4 -n 120" > /dev/null 2>&1
	check audioloss-video-after $? "(video capture after the relock)"
	# idle loss and relock
	src_off
	sleep 4
	av_on
	check audioloss-relock-idle $? "(after an idle loss)"
	echo "  last relock $(( $(date +%s) - t0 )) s into the 80 s capture"
	wait $p
	rc=$?
	out=$(vm "grep -E '^(RESULT|XRUN)' $W/aloss.txt")
	check audioloss-capture "$rc" "($out)"
	d1=$(aud_dbg)
	echo "$d1" | sed 's/^/  /'
	# the video stops leave the audio DMA's reset domain alone (open
	# question 13): no restart
	check audioloss-restarts "$([ "$(( $(aud_stat "$d1" restarts) - $(aud_stat "$d0" restarts) ))" = 0 ] &&
		[ "$(aud_stat "$d1" stop_missing)" = "$(aud_stat "$d0" stop_missing)" ]; echo $?)" \
		"($(( $(aud_stat "$d1" restarts) - $(aud_stat "$d0" restarts) )) DMA restarts across 7 video stops, $(( $(aud_stat "$d1" pauses) - $(aud_stat "$d0" pauses) )) pauses (input loss), $(( $(aud_stat "$d1" filled) - $(aud_stat "$d0" filled) )) frames filled)"
	# never stalled: no read more than 250 ms after the one before (a pause
	# at an input loss holds one period up by 10 ms)
	out=$(vm "awk '/^A /{ split(\$4, t, \"=\"); if (p && t[2] - p > m) m = t[2] - p; p = t[2] } END { printf \"%.1f\", m / 1e6 }' $W/aloss.txt")
	check audioloss-stall "$(awk -v m="$out" 'BEGIN { exit !(m < 250) }'; echo $?)" "(longest time between reads $out ms)"
	out=$(vm "python3 $W/live-av.py $W/aloss.txt $W/aloss.raw --tail 20")
	# the input losses' pauses are filled and the video stops leave audio
	# alone: the stream keeps time through all of them
	av_results audioloss "$(grep -E '^RESULT (tail|channels|xruns|rate|gaps) ' <<< "$out")"
	grep -E '^RESULT bursts ' <<< "$out" | sed 's/^RESULT/  info:/'
	av_off
}

# ---- M5: OBS in the VM (tests/obs-run.sh, obs-check.py, obs-av.py) ----

# obs-check.py as the desktop user: OBS runs in the VM's Xfce session
obsc() { vm "cd $W && GC573_OBS_BUFFERING=$OBS_BUFFERING python3 obs-check.py $*"; }

# OBS running, with the card's V4L2 and ALSA sources in its scene
# OBS's sources by stable names: the video device by its PCI path, the
# ALSA PCM by the card's id
# obs_up [FORMAT]: the recording format (tests/obs-run.sh), default hybrid_mp4
obs_up() {
	vm "GC573_OBS_RECFORMAT=${1:-hybrid_mp4} bash $W/obs-run.sh start" | sed 's/^/  /' &&
		obsc "setup /dev/v4l/by-path/pci-${dbgdir#*/gc573-}-video-index0 $pcm" | sed 's/^/  /'
}

# OBS holds the device while it runs: each OBS step stops it at the end
obs_down() { vm "bash $W/obs-run.sh stop" > /dev/null; }

# Lines in OBS's current log, and OBS's capture-source lines after line $1
obs_log_mark() { vm 'wc -l < "$(ls -t ~/.config/obs-studio/logs/*.txt | head -1)"'; }
obs_log_since() {
	vm "tail -n +$(($1 + 1)) \"\$(ls -t ~/.config/obs-studio/logs/*.txt | head -1)\"" |
		grep -E 'v4l2-input|alsa-input|Recording (Start|Stop)'
}

# Every pixel format OBS offers for the device, through OBS's own
# conversion: a source screenshot against pattern.py
step_obs() {
	src_mode 1920x1080 60
	obs_up || { result obs-start FAIL "(OBS with obs-websocket: tests/obs-run.sh)"; obs_down; return; }
	vm "python3 $W/pattern.py $W/pattern-1080.png 1920 1080 >/dev/null"
	av_results obs "$(obsc "formats $W/pattern-1080.png")"
	obs_down
}

# GC573_OBS_SECS (600) of OBS recording avsync.sh (V4L2 source with OBS's
# defaults, ALSA source): A/V offset and drift measured in the file, OBS's
# frame counters, and no capture trouble in OBS's log. Before it, in the
# same avsync.sh session, 60 s with the driver's timestamps (live-av.py)
# give the source's own offset; the difference is OBS's
step_obsav() {
	local out f m lg ref obsm
	av_on || { result obsav-source FAIL "(avsync.sh or the IT6805 audio state ON)"; av_off; return; }
	sleep 3
	# The source's own offset in this avsync.sh session, from the driver's
	# timestamps as in step avsync, for 60 s: it can differ by whole frames
	# from one session to the next. OBS's own part is the difference
	vm "sudo $W/gc573-aud -D $pcm -t 60 -v -V $vdev -o $W/av.raw > $W/av.txt 2>&1"
	out=$(vm "python3 $W/live-av.py $W/av.txt $W/av.raw --min-secs 54")
	vm "rm -f $W/av.raw"
	av_results obsav-driver "$(grep -E '^RESULT (duration|avsync)|raw offsets' <<< "$out")"
	ref=$(sed -n 's/^  raw offsets: mean \([-+0-9.]*\) ms.*/\1/p' <<< "$out")
	obs_up || { result obsav-start FAIL "(OBS with obs-websocket)"; obs_down; av_off; return; }
	m=$(obs_log_mark)
	out=$(obsc "record $OBS_SECS")
	f=$(sed -n 's/^RECORDING //p' <<< "$out")
	check obsav-record "$([ -n "$f" ]; echo $?)" "($(grep '^STATS' <<< "$out"))"
	lg=$(obs_log_since "$m")
	sed 's/^/  obs: /' <<< "$lg" | head -20
	check obsav-obs-log "$(! grep -qE 'select timed out|failed to dequeue|failed to log status' <<< "$lg"; echo $?)" \
		"($(grep -cE 'select timed out' <<< "$lg") select timeouts, $(grep -cE 'failed to dequeue' <<< "$lg") dequeue failures)"
	if [ -n "$f" ]; then
		out=$(vm "python3 $W/obs-av.py '$f' --min-secs $((OBS_SECS * 9 / 10)) ${ref:+--ref $ref}")
		av_results obsav "$out"
		vm "rm -f '$f'"
		obsm=$(sed -n 's/^RESULT offset .*: mean \([-+0-9.]*\) ms.*/\1/p' <<< "$out")
		[ -n "$ref" ] && [ -n "$obsm" ] && awk -v o="$obsm" -v d="$ref" 'BEGIN {
			printf "  OBS - driver in this session: %+.2f ms (OBS %+.2f, driver %+.2f: burst onset - flash frame)\n", o - d, o, d }'
	fi
	obs_down
	av_off
}

# Source changes while OBS records: output off and on, then a change to
# 720p, with the V4L2 source left alone. Live = flash frames in the
# recording (obs-av.py --segments). At other timings the driver fails the
# queue and OBS's source stops (OBS ignores V4L2 source-change events):
# after the recording (whose muxer process holds the device: obs-check.py)
# the source is reopened as a user would (obs-check.py reopen), at 720p
# and again after a change to 1080p, and must show the pattern.
step_obschange() {
	local out f m lg t0 marks="" seg n k w h
	local names=(before off on 720p)
	av_on || { result obschange-source FAIL "(avsync.sh or the IT6805 audio state ON)"; av_off; return; }
	sleep 3
	obs_up || { result obschange-start FAIL "(OBS with obs-websocket)"; obs_down; av_off; return; }
	m=$(obs_log_mark)
	obsc start > /dev/null || { result obschange-record FAIL "(StartRecord)"; obs_down; av_off; return; }
	t0=$(date +%s%N)
	mark() { marks+="${marks:+,}$(( ($(date +%s%N) - t0) / 1000000 )).0e-3"; }
	sleep 12
	mark; src_off; sleep 8
	mark; av_on; sleep 12
	mark; "$ROOT/tools/testsrc/avsync.sh" "$OUT" 1280x720 60 > /dev/null 2>&1; sleep 8
	out=$(obsc stop)
	f=$(sed -n 's/^RECORDING //p' <<< "$out")
	check obschange-record "$([ -n "$f" ]; echo $?)" "($(grep '^STATS' <<< "$out"))"
	lg=$(obs_log_since "$m")
	sed 's/^/  obs: /' <<< "$lg" | grep -vE 'select timed out' | head -30
	echo "  obs: $(grep -c 'select timed out' <<< "$lg") select timeouts"
	if [ -n "$f" ]; then
		marks=$(python3 -c "print(','.join(f'{float(x):.1f}' for x in '$marks'.split(',')))")
		out=$(vm "python3 $W/obs-av.py '$f' --segments $marks")
		grep -E '^(SEGMENT|RESULT video)' <<< "$out" | sed 's/^/  /'
		for k in 0 1 2 3; do
			seg=$(awk -v k=$k '$1 == "SEGMENT" && $2 == k' <<< "$out")
			n=$(grep -o 'flashes=[0-9]*' <<< "$seg" | cut -d= -f2)
			case ${names[$k]} in
			before|on)
				check "obschange-live-${names[$k]}" "$([ "${n:-0}" -ge 5 ]; echo $?)" \
					"(${n:-0} flash frames in ${names[$k]}: $(cut -d' ' -f3-4 <<< "$seg") s)" ;;
			*)
				echo "  ${names[$k]}: ${n:-0} flash frames" ;;
			esac
		done
		vm "rm -f '$f'"
	fi
	check obschange-stopped-720p "$(grep -q 'failed to dequeue' <<< "$lg"; echo $?)" \
		"(OBS's source stops at other timings: $(grep -c 'failed to dequeue' <<< "$lg") dequeue failure)"
	av_off
	for w in 1280 1920; do
		h=$((w * 9 / 16))
		vm "[ -f $W/p-${w}x$h.png ] || python3 $W/pattern.py $W/p-${w}x$h.png $w $h >/dev/null"
		src_on "${w}x$h" 60
		time_to_lock 10 > /dev/null
		sleep 3
		obsc reopen
		sleep 4
		av_results obschange-reopen "$(obsc "pattern $w $h $W/p-${w}x$h.png")"
	done
	obs_down
}

# PipeWire on the card or off it again (the VM's udev rule lifted: $1 = on;
# put back: off). WirePlumber reads the rule's ACP_IGNORE when it starts.
# In a virtual machine WirePlumber gives every ALSA node 8192 frames of
# headroom (vm.node.defaults in its 50-alsa-config.lua), which PipeWire
# keeps in the capture buffer: 170 ms more latency than on bare metal,
# and OBS's PulseAudio source ignores latency. While on, a rule
# (tests/obspw.lua) takes that headroom off the card's node, as on a desktop
pw_card() {
	if [ "$1" = on ]; then
		vm "[ ! -e $PW_RULE ] || sudo mv $PW_RULE $PW_RULE.off; mkdir -p \$(dirname ~/$PW_WP)"
		scp -q -o ControlPath="$SSHCTL" "$ROOT/tests/obspw.lua" "$VM:$PW_WP"
	else
		vm "rm -f ~/$PW_WP; [ ! -e $PW_RULE.off ] || sudo mv $PW_RULE.off $PW_RULE"
	fi
	vm "sudo udevadm control --reload && sudo udevadm trigger -s sound -c change &&
		sudo udevadm settle && systemctl --user restart wireplumber"
}

# OBS with the card's audio through PipeWire, as on a desktop: obsav's
# recording and analysis with a PulseAudio source on the card's PipeWire
# source instead of the ALSA source. Afterwards PipeWire lets go of the
# card again: nothing holds the module (refcnt 0; while PipeWire manages
# a card it keeps the card's control device open)
step_obspw() {
	local bdf node out f m lg i rc
	bdf=${dbgdir##*/gc573-}
	av_on || { result obspw-source FAIL "(avsync.sh or the IT6805 audio state ON)"; av_off; return; }
	sleep 3
	pw_card on
	for i in $(seq 40); do
		node=$(vm "pactl list short sources" | awk -v d="pci-${bdf//:/_}" \
			'index($2, d) && $2 !~ /\.monitor$/ { print $2; exit }')
		[ -n "$node" ] && break
		sleep 0.5
	done
	vm "pactl list cards" | grep -A3 -E "Name: .*${bdf//:/_}" | sed 's/^/  pw: /'
	check obspw-pipewire "$([ -n "$node" ]; echo $?)" "(PipeWire source: ${node:-none})"
	if [ -n "$node" ]; then
		if obs_up && obsc "pulse $node" | sed 's/^/  /'; then
			m=$(obs_log_mark)
			obsc start > /dev/null
			sleep $((PW_SECS / 2))
			# frames captured that PipeWire has not read yet
			echo "  ALSA, half-way: $(vm "grep -E 'period_size|buffer_size' /proc/asound/GC573/pcm0c/sub0/hw_params;
				grep -E '^delay' /proc/asound/GC573/pcm0c/sub0/status" | tr -s ' \n' ' ')"
			sleep $((PW_SECS - PW_SECS / 2))
			out=$(obsc stop)
			f=$(sed -n 's/^RECORDING //p' <<< "$out")
			check obspw-record "$([ -n "$f" ]; echo $?)" "($(grep '^STATS' <<< "$out"))"
			lg=$(vm "tail -n +$((m + 1)) \"\$(ls -t ~/.config/obs-studio/logs/*.txt | head -1)\"" |
				grep -E 'pulse-input|v4l2-input|Recording (Start|Stop)')
			sed 's/^/  obs: /' <<< "$lg" | head -20
			if [ -n "$f" ]; then
				out=$(vm "python3 $W/obs-av.py '$f' --min-secs $((PW_SECS * 9 / 10))")
				av_results obspw "$out"
				vm "rm -f '$f'"
			fi
			obsc "pulse off" > /dev/null
		else
			result obspw-start FAIL "(OBS with obs-websocket and the PipeWire source)"
		fi
		obs_down
	fi
	av_off
	pw_card off
	for i in $(seq 40); do
		rc=$(vm "cat /sys/module/gc573/refcnt")
		[ "$rc" = 0 ] && break
		sleep 0.5
	done
	check obspw-released "$([ "$rc" = 0 ]; echo $?)" \
		"(rule back; gc573 refcnt $rc$(vm "pactl list short sources" | grep -q "${bdf//:/_}" && echo ', PipeWire still lists the card'))"
}

# M5: GC573_SOAK_SECS of continuous audio and video capture (gate: 2 h on
# the generic kernel, 30 min on the debug kernel). The capture runs
# detached in the VM (an ssh session need not last the run); a sampler
# logs memory and CPU time every minute. Before each sample it drops the
# page cache and the reclaimable slab (sync, drop_caches 3): the capture's
# own files (soak.raw, 1.4 GB in 2 h) otherwise grow buffer_head,
# radix_tree_node and memcg's slab vectors (kmalloc-512) by 0.4 MB a
# minute, all of it cache that a drop frees.
step_soak() {
	local out d0 d1 n bad="" i t0 sm rc
	av_on || { result soak-source FAIL "(avsync.sh or the IT6805 audio state ON)"; av_off; return; }
	sleep 3
	d0=$(aud_dbg)
	vm "rm -f $W/soak.raw $W/soak.txt $W/soak-mem.txt"
	vm "sudo nohup bash -c 'while :; do
		irq=\$(ps -eo pid,comm | awk '\''\$2 ~ /^irq\\/[0-9]+-gc573/ { print \$1; exit }'\'')
		aud=\$(pgrep -x gc573-aud | head -1)
		sync; echo 3 > /proc/sys/vm/drop_caches
		printf \"%s %s %s %s %s %s %s\\n\" \$(date +%s) \
			\$(awk '\''/^(MemAvailable|Slab|SUnreclaim):/ { printf \"%s \", \$2 }'\'' /proc/meminfo) \
			\$(awk '\''{ print \$14 + \$15 }'\'' /proc/\${aud:-0}/stat 2>/dev/null || echo -) \
			\$(awk '\''{ print \$14 + \$15 }'\'' /proc/\${irq:-0}/stat 2>/dev/null || echo -) \
			\$(awk '\''/^cpu / { print \$2 + \$3 + \$4 + \$6 + \$7 + \$8, \$5 }'\'' /proc/stat | tr \" \" :)
		sleep 60
	done' > $W/soak-mem.txt 2>&1 < /dev/null & echo \$! > $W/soak-sampler.pid"
	vm "sudo nohup $W/gc573-aud -D $pcm -t $SOAK_SECS -v -V $vdev -o $W/soak.raw > $W/soak.txt 2>&1 < /dev/null & echo \$! > $W/soak.pid"
	t0=$(date +%s)
	echo "  soak: $SOAK_SECS s from $(date -u '+%H:%M:%S UTC')"
	sleep 5
	while vm "sudo kill -0 \$(cat $W/soak.pid) 2>/dev/null"; do
		[ $(( $(date +%s) - t0 )) -lt $((SOAK_SECS + 600)) ] || { vm "sudo kill \$(cat $W/soak.pid)"; break; }
		sleep 30
	done
	vm "sudo kill \$(cat $W/soak-sampler.pid)"
	check soak-capture "$(vm "grep -q '^RESULT' $W/soak.txt"; echo $?)" \
		"($(vm "grep -E '^(PARAMS|RESULT)' $W/soak.txt" | tr '\n' ' '))"
	d1=$(aud_dbg)
	echo "$d1" | sed 's/^/  /'
	for n in late order bad_done stop_missing; do
		[ "$(aud_stat "$d0" $n)" = "$(aud_stat "$d1" $n)" ] ||
			bad+=" $n +$(( $(aud_stat "$d1" $n) - $(aud_stat "$d0" $n) ))"
	done
	check soak-periods "$([ -z "$bad" ]; echo $?)" \
		"(driver: $(( $(aud_stat "$d1" periods) - $(aud_stat "$d0" periods) )) periods, $(( $(aud_stat "$d1" pauses) - $(aud_stat "$d0" pauses) )) source pauses filled with $(( $(aud_stat "$d1" filled) - $(aud_stat "$d0" filled) )) frames${bad:-; none late or out of order})"
	vm "sudo cat $dbgdir/video" | grep -E '^(stream|stats):' | sed 's/^/  /'
	out=$(vm "python3 $W/live-av.py $W/soak.txt $W/soak.raw --min-secs $((SOAK_SECS * 99 / 100))")
	av_results soak "$out"
	# memory and CPU over the run: the first sample after 5 min against the
	# last one taken while gc573-aud ran (allocations settle; what the stop
	# frees must not hide growth during the stream); kB
	sm=$(vm "cat $W/soak-mem.txt")
	echo "$sm" | awk 'NR == 1 || NR % 10 == 0 { print "  mem: " $0 }'
	out=$(awk -v hz="$(vm getconf CLK_TCK)" '
		NF >= 7 { n++; t[n] = $1; avail[n] = $2; slab[n] = $3; sunr[n] = $4; aud[n] = $5; irq[n] = $6
			split($7, c, ":"); busy[n] = c[1]; idle[n] = c[2]; if ($5 != "-") l = n }
		END {
			a = (l > 6) ? 6 : 1
			ds = slab[l] - slab[a]; du = sunr[l] - sunr[a]; dm = avail[a] - avail[l]
			wall = t[l] - t[1]
			printf "%d samples over %.0f min while capturing; from minute 5: Slab %+d kB, SUnreclaim %+d kB, MemAvailable %+d kB", l, wall / 60, ds, du, -dm
			if (wall > 0 && aud[1] != "-")
				printf "; CPU: gc573-aud %.2f %% of one CPU", (aud[l] - aud[1]) / hz / wall * 100
			if (wall > 0 && irq[l] != "-" && irq[1] != "-")
				printf ", IRQ thread %.2f %%", (irq[l] - irq[1]) / hz / wall * 100
			if (busy[l] + idle[l] > busy[1] + idle[1])
				printf ", VM total %.1f %% of %d CPUs", (busy[l] - busy[1]) * 100 / (busy[l] - busy[1] + idle[l] - idle[1]), cpus
			exit !(l >= 3 && du < 2048 && ds < 4096)
		}' cpus="$(vm nproc)" <<< "$sm")
	rc=$?
	# On a KASAN kernel (the debug kernel) slab grows with any activity,
	# idle too: KASAN's quarantine keeps freed objects (up to 1/32 of RAM).
	# There kmemleak is the leak check, and the figures are only reported
	if vm "grep -qx 'CONFIG_KASAN=y' /boot/config-\$(uname -r)"; then
		result soak-memory SKIP "(KASAN kernel, figures only: $out)"
	else
		check soak-memory $rc "($out)"
	fi
	vm "rm -f $W/soak.raw"
	av_off
}

# M5: the driver's A/V timing across source changes that restart the
# stream, under one avsync.sh session (the source is not restarted): the
# GPU's colour format three times (each a free-running restart and a live
# one, 0.2-0.4 s without frames). One gc573-aud -V capture; per segment
# between the changes the offset (live-av.py --segments, corrected by whole
# frames as in avsync) must stay within 1 ms of the first segment's. OBS
# with buffering on adds every such gap to its video delay (README); the
# driver's timestamps must not
step_avchange() {
	local out p t0 k st n dmax offs
	av_on || { result avchange-source FAIL "(avsync.sh or the IT6805 audio state ON)"; av_off; return; }
	sleep 3
	vm "sudo $W/gc573-aud -D $pcm -t 80 -v -V $vdev -o $W/avc.raw > $W/avc.txt 2>&1" &
	p=$!
	t0=$(date +%s)
	for k in "20 2 1" "40 0 1" "60 0 0"; do
		set -- $k
		while [ $(($(date +%s) - t0)) -lt "$1" ]; do sleep 0.1; done
		ev "colour ColorSpace=$2 ColorRange=$3"
		nvidia-settings --no-write-config -a "[DPY:$OUT]/ColorSpace=$2" -a "[DPY:$OUT]/ColorRange=$3" > /dev/null 2>&1
	done
	wait $p
	check avchange-capture $? "($(vm "grep -E '^(PARAMS|RESULT)' $W/avc.txt" | tr '\n' ' '))"
	out=$(vm "python3 $W/live-av.py $W/avc.txt $W/avc.raw --segments 20,40,60")
	vm "rm -f $W/avc.raw"
	grep -E '^SEGMENT|raw offsets|^RESULT (video|gaps)' <<< "$out" | sed 's/^/  /'
	out=$(awk '/^SEGMENT/ { for (i = 1; i <= NF; i++) if ($i ~ /^corr=/) { c = substr($i, 6) + 0; n++
			if (n == 1) c0 = c; d = c - c0; if (d < 0) d = -d; if (d > dmax) dmax = d; s = s sprintf(" %+.3f", c) } }
		END { printf "%s %d %.3f%s", (n == 4 && dmax <= 1) ? "PASS" : "FAIL", n, dmax, s }' <<< "$out")
	read -r st n dmax offs <<< "$out"
	result avchange-offset "$st" "($n segments around 3 colour changes, each a free-running and a live restart: offsets $offs ms, at most $dmax ms from the first; limit 1)"
	vm "sudo cat $dbgdir/video" | grep -o -E 'input_restarts [0-9]+ input_stops [0-9]+' | sed 's/^/  /'
	av_off
}

# M5, OBS as the consumer, driven through obs-websocket from the host
# (tests/obs-events.py; the same clock as the source changes): the V4L2
# source and the ALSA source by stable names (obs_up); GetSourceScreenshot of
# the V4L2 source against the pattern, with its request time; the ALSA
# source's InputVolumeMeters events against avsync.sh's bursts; a 60 s
# recording: its image (pattern, counter steps) and its A/V offset (the
# source's own offset needs avsync.sh's full-frame flash: step obsav)
step_obsws() {
	local out f
	av_on --pattern || { result obsws-source FAIL "(avsync.sh --pattern or the IT6805 audio state ON)"; av_off; return; }
	sleep 3
	obs_up || { result obsws-start FAIL "(OBS with obs-websocket)"; obs_down; av_off; return; }
	sleep 3
	av_results obsws "$(python3 "$ROOT/tests/obs-events.py" shots 10 2>&1)"
	av_results obsws "$(python3 "$ROOT/tests/obs-events.py" meters 20 2>&1)"
	out=$(obsc "record 60")
	f=$(sed -n 's/^RECORDING //p' <<< "$out")
	check obsws-record "$([ -n "$f" ]; echo $?)" "($(grep '^STATS' <<< "$out"))"
	if [ -n "$f" ]; then
		av_results obsws "$(vm "cd $W && python3 obs-events.py recheck '$f' --every 5" 2>&1)"
		out=$(vm "python3 $W/obs-av.py '$f' --box 0.70,0.88,0.92,0.92 --min-secs 55" 2>&1)
		av_results obsws-rec "$out"
		vm "rm -f '$f'"
	fi
	obs_down
	av_off
}

# M5: OBS's V4L2 source through every source change, unattended: a sleep and
# wake, 60 <-> 59.94 Hz, 1080p <-> 720p (OBS cannot follow a new frame size by
# itself; the step then reopens the source through the websocket), the GPU's
# colour format, and EDID re-sets (tests/obs-events.py events). TTFGF per
# change; OBS's own log lines for its capture.
step_obsevents() {
	local out m lg f
	obs_up || { result obsevents-start FAIL "(OBS with obs-websocket)"; obs_down; return; }
	m=$(obs_log_mark)
	out=$(python3 "$ROOT/tests/obs-events.py" events --reps "$OBSEV_REPS" 2>&1)
	av_results obsevents "$out"
	lg=$(obs_log_since "$m")
	echo "  obs: $(grep -c 'select timed out' <<< "$lg") select timeouts, $(grep -c 'failed to dequeue' <<< "$lg") dequeue failures, $(grep -c 'Start capture' <<< "$lg") device opens"
	# The frame-size changes again while OBS records. Hybrid MP4 (OBS was
	# started with it) is OBS's own muxer: the reopen works during the
	# recording, which must play the pattern before and after. MKV runs the
	# obs-ffmpeg-mux helper, which holds OBS's descriptor of the device: the
	# reopen cannot work until the recording stops (report only)
	out=$(python3 "$ROOT/tests/obs-events.py" events --reps 1 --only res-720p,res-1080p --record 2>&1)
	grep '^RECFORMAT' <<< "$out" | sed 's/^/  /'
	av_results obsevents-hybrid "$(grep -v '^RECFORMAT' <<< "$out")"
	f=$(sed -n 's/^RECORDING //p' <<< "$out")
	if [ -n "$f" ]; then
		av_results obsevents-hybrid "$(vm "cd $W && python3 obs-events.py recheck '$f' --every 2 --across" 2>&1)"
		vm "rm -f '$f'"
	fi
	obs_log_since "$m" | grep -E 'Unable to set format|failed to|busy' | sed 's/^/  obs log: /' | head -8
	obs_down
	obs_up mkv > /dev/null || { result obsevents-mkv-start FAIL "(OBS with obs-websocket)"; obs_down; return; }
	m=$(obs_log_mark)
	out=$(python3 "$ROOT/tests/obs-events.py" events --reps 1 --only res-720p,res-1080p --record 2>&1)
	grep -E '^RECFORMAT|^ *EVENT|^RESULT' <<< "$out" |
		sed 's/^RESULT/  INFO mkv (report only):/; s/^ *EVENT/  mkv: EVENT/; s/^RECFORMAT/  RECFORMAT/'
	f=$(sed -n 's/^RECORDING //p' <<< "$out")
	[ -z "$f" ] || vm "rm -f '$f'"
	obs_log_since "$m" | grep -E 'Unable to set format|failed to|busy' | sed 's/^/  mkv: obs log: /' | head -8
	obs_down
}

# M5: the event soak with OBS as the consumer: GC573_OBSSOAK_SECS (7200) of
# OBS recording, a screenshot every 2 s from the host, and every
# GC573_OBSSOAK_EVERY s (180) the next source change from a rotation
# (tests/obs-events.py soak). Then the recording (pattern, counter steps, A/V
# offset between the changes), memory and slab (page cache dropped before
# each sample, as in step soak), CPU, and OBS's log. The guard watches it all.
step_obssoak() {
	local out f m lg sm marks
	obs_up || { result obssoak-start FAIL "(OBS with obs-websocket)"; obs_down; return; }
	m=$(obs_log_mark)
	vm "rm -f $W/obssoak-mem.txt"
	vm "sudo nohup bash -c 'while :; do
		irq=\$(ps -eo pid,comm | awk '\''\$2 ~ /^irq\\/[0-9]+-gc573/ { print \$1; exit }'\'')
		obs=\$(pgrep -x obs | head -1)
		sync; echo 3 > /proc/sys/vm/drop_caches
		printf \"%s %s %s %s %s %s %s\\n\" \$(date +%s) \
			\$(awk '\''/^(MemAvailable|Slab|SUnreclaim):/ { printf \"%s \", \$2 }'\'' /proc/meminfo) \
			\$(awk '\''{ print \$14 + \$15 }'\'' /proc/\${obs:-0}/stat 2>/dev/null || echo -) \
			\$(awk '\''{ print \$14 + \$15 }'\'' /proc/\${irq:-0}/stat 2>/dev/null || echo -) \
			\$(awk '\''/^cpu / { print \$2 + \$3 + \$4 + \$6 + \$7 + \$8, \$5 }'\'' /proc/stat | tr \" \" :)
		sleep 60
	done' > $W/obssoak-mem.txt 2>&1 < /dev/null & echo \$! > $W/obssoak-sampler.pid"
	echo "  obssoak: $OBSSOAK_SECS s from $(date -u '+%H:%M:%S UTC'), a change every $OBSSOAK_EVERY s"
	out=$(python3 "$ROOT/tests/obs-events.py" soak "$OBSSOAK_SECS" --every "$OBSSOAK_EVERY" 2>&1)
	vm "sudo kill \$(cat $W/obssoak-sampler.pid)"
	av_results obssoak "$(grep -v '^SHOT ' <<< "$out")"
	echo "  screenshots that were not good: $(grep -c '^SHOT ' <<< "$out") (SHOT lines in the event log's run)"
	grep '^SHOT ' <<< "$out" > "${log%.log}-obssoak-shots.txt"
	f=$(sed -n 's/^RECORDING //p' <<< "$out")
	marks=$(sed -n 's/^MARK //p' <<< "$out" | paste -sd,)
	if [ -n "$f" ]; then
		av_results obssoak "$(vm "cd $W && python3 obs-events.py recheck '$f' --every 30 --across" 2>&1)"
		av_results obssoak-rec "$(vm "python3 $W/obs-av.py '$f' --box 0.70,0.88,0.92,0.92 ${marks:+--segments $marks}" 2>&1)"
		vm "rm -f '$f'"
	fi
	sm=$(vm "cat $W/obssoak-mem.txt")
	echo "$sm" | awk 'NR == 1 || NR % 10 == 0 { print "  mem: " $0 }'
	out=$(awk -v hz="$(vm getconf CLK_TCK)" '
		NF >= 7 { n++; t[n] = $1; avail[n] = $2; slab[n] = $3; sunr[n] = $4; obs[n] = $5; irq[n] = $6
			split($7, c, ":"); busy[n] = c[1]; idle[n] = c[2] }
		END {
			if (n < 7) { print "RESULT memory SKIP (" n " samples: fewer than 7)"; exit }
			s = 6
			ds = slab[n] - slab[s]; du = sunr[n] - sunr[s]
			printf "RESULT memory %s (from minute 5 to the end: MemAvailable %+d kB, Slab %+d kB, SUnreclaim %+d kB; limits Slab 4096, SUnreclaim 2048)\n",
				(ds <= 4096 && du <= 2048) ? "PASS" : "FAIL", avail[n] - avail[s], ds, du
			wall = t[n] - t[1]
			printf "RESULT cpu PASS (report only: OBS %.1f %% of one CPU, the IRQ thread %.2f %%, the VM %.1f %% of its CPUs, over %d s)\n",
				(obs[n] - obs[1]) / hz / wall * 100, (irq[n] - irq[1]) / hz / wall * 100,
				(busy[n] - busy[1]) / ((busy[n] - busy[1]) + (idle[n] - idle[1])) * 100, wall
		}' <<< "$sm")
	av_results obssoak "$out"
	lg=$(obs_log_since "$m")
	echo "  obs: $(grep -c 'select timed out' <<< "$lg") select timeouts, $(grep -c 'failed to dequeue' <<< "$lg") dequeue failures, $(grep -c 'Start capture' <<< "$lg") device opens"
	obs_down
}

# Unload while streaming live video and audio. rmmod is refused while the
# devices are open (module in use) and the streams keep running; unbinding
# the PCI device stops them (the applications see an error and exit)
# within 5 s; rebinding probes again and the input locks; rmmod then works.
step_unload() {
	local bdf rc t0 t f0 f1 lt
	bdf=${dbgdir##*/gc573-}
	src_mode 1920x1080 60
	vm "sudo $W/gc573-cap -d $vdev -f NV12 -b 4 -n 100000 -D $dbgdir/video" \
		> /tmp/gc573-live-u.txt 2>&1 &
	local p=$!
	aud "-t 100000" > /tmp/gc573-live-ua.txt 2>&1 &
	local pa=$!
	sleep 3
	f0=$(vm "sudo grep -o 'frames [0-9]*' $dbgdir/video" | head -1)
	vm "sudo rmmod gc573" > /tmp/gc573-live-rm.txt 2>&1
	rc=$?
	sleep 1
	f1=$(vm "sudo grep -o 'frames [0-9]*' $dbgdir/video" | head -1)
	check unload-rmmod-in-use "$([ $rc != 0 ] && grep -q 'in use' /tmp/gc573-live-rm.txt &&
		[ -n "$f0" ] && [ "$f0" != "$f1" ]; echo $?)" \
		"($(head -1 /tmp/gc573-live-rm.txt); stream $f0 -> $f1)"
	t0=$(date +%s%N)
	vm "echo $bdf | sudo tee /sys/bus/pci/drivers/gc573/unbind >/dev/null"
	rc=$?
	t=$((($(date +%s%N) - t0) / 1000000))
	wait $p
	wait $pa
	echo "  capture tool: $(grep -E '^(FAIL|RESULT)|error|failed' /tmp/gc573-live-u.txt | head -3 | tr '\n' ' ')"
	echo "  audio tool: $(grep -E '^RESULT|error|failed|read' /tmp/gc573-live-ua.txt | head -3 | tr '\n' ' ')"
	check unload-unbind-streaming "$([ $rc = 0 ] && [ $t -lt 5000 ]; echo $?)" "(unbind $t ms, both applications exited)"
	vm "echo $bdf | sudo tee /sys/bus/pci/drivers/gc573/bind >/dev/null"
	find_vdev
	lt=$(time_to_lock 15)
	check unload-rebind-lock $? "(locked $lt ms after the bind returned)"
	vm "sudo rmmod gc573"
	check unload-rmmod $? ""
	load
}

step_reload() {
	local i ok=0 lockfail=0 hostfail=0 t tmax=0
	for i in $(seq "$RELOADS"); do
		unload
		load || { lockfail=$((lockfail + 1)); continue; }
		if ! wait_connected 15; then
			hostfail=$((hostfail + 1))
			continue
		fi
		src_on 1920x1080 60
		if t=$(time_to_lock 15); then
			ok=$((ok + 1))
			[ "$t" -gt "$tmax" ] && tmax=$t
		else
			lockfail=$((lockfail + 1))
		fi
	done
	check reload "$([ $ok = "$RELOADS" ]; echo $?)" \
		"($ok of $RELOADS locked, host output lost $hostfail, no lock $lockfail, slowest lock $tmax ms after the output came back)"
}

step_compliance() {
	local out
	src_on 1920x1080 60
	time_to_lock 10 >/dev/null
	vm "v4l2-ctl -d $vdev --query-dv-timings >/dev/null && v4l2-ctl -d $vdev --set-dv-bt-timings query >/dev/null"
	out=$(vm "v4l2-compliance -d $vdev -s 2>&1")
	echo "$out" | grep -E 'fail|warn|Total for' | sed 's/^/  /'
	check compliance "$(grep -q 'Failed: 0, Warnings: 0' <<< "$out"; echo $?)" \
		"($(echo "$out" | grep 'Total for'))"
}

# Kernel log since the start: a warning, oops, KASAN/UBSAN, lockdep,
# atomic-sleep or DMA-API report or a driver error fails, as in run.sh
# (tests/lib.sh KMSG_BAD, KMSG_DRV_BAD)
kmsg_check() {
	local log bad
	# shellcheck source=tests/lib.sh
	. "$ROOT/tests/lib.sh"
	log=$(vm "sudo dmesg | awk -v m='gc573-live: $kmark' 'f; index(\$0, m) { f = 1 }'")
	bad=$( { echo "$log" | grep -E "$KMSG_BAD"; echo "$log" | grep -E "$KMSG_DRV_BAD"; } | head -10)
	echo "  kernel log: $(echo "$log" | grep -c gc573) driver lines"
	[ -z "$bad" ] || echo "$bad" | sed 's/^/  | /'
	check kernel-log "$([ -z "$bad" ]; echo $?)" "($krel)"
}

# kmemleak over the run, as run.sh does (tests/lib.sh kml_reset and
# kml_report: two scans each, automatic scans paused meanwhile); SKIP where
# the kernel has no kmemleak. $1: reset (at the start) or report.
KML=/sys/kernel/debug/kmemleak
kml() {
	local leaks
	vm "sudo test -w $KML" || {
		[ "$1" = reset ] || result kmemleak SKIP "(no kmemleak on $krel)"
		return 0
	}
	if [ "$1" = reset ]; then
		vm "sudo sh -c 'echo scan=off > $KML; echo scan > $KML; echo scan > $KML; echo clear > $KML'"
		return
	fi
	leaks=$(vm "sudo sh -c 'sleep 6; echo scan > $KML; echo scan > $KML; cat $KML; echo scan=on > $KML'")
	[ -z "$leaks" ] || sed 's/^/  | /' <<< "$leaks" | head -60
	check kmemleak "$([ -z "$leaks" ]; echo $?)" \
		"($(grep -c 'unreferenced object' <<< "$leaks") unreferenced objects)"
}

# ---- main ----

all="bringup lock relock capture modes change loss colour audio avsync audioloss"
all+=" obs obsav obschange obsws obsevents avchange unload reload compliance"
[ $# -gt 0 ] || set -- $all
krel=$(vm uname -r) || exit 2
stamp=$(date -u +%Y%m%d-%H%M%S)
log=$ROOT/tests/logs/${stamp}_${krel}_live.log
mkdir -p "$ROOT/tests/logs"
# the run's event log, and the guard (tools/testsrc/guard.py): a test window
# outside the output, or test audio on any sink but the NVIDIA HDMI one,
# stops the run
export GC573_EVENT_LOG=${log%.log}-events.log GC573_GUARDED=1
python3 "$ROOT/tools/testsrc/guard.py" --pid $$ --log "$GC573_EVENT_LOG" --output "$OUT" &
trap 'vm "[ ! -e $PW_RULE.off ] || { rm -f ~/$PW_WP; sudo mv $PW_RULE.off $PW_RULE; sudo udevadm control --reload;
		sudo udevadm trigger -s sound -c change; systemctl --user restart wireplumber; }"
	"$ROOT/tools/testsrc/show.sh" --off; "$ROOT/tools/testsrc/avsync.sh" --off
	ssh -O exit -o ControlPath="$SSHCTL" "$VM" 2>/dev/null' EXIT
{
	echo "# GC573 live-input suite (PC loopback)"
	echo "date:    $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
	echo "vm:      $VM, kernel $krel"
	echo "rev:     $(git -C "$ROOT" describe --always --dirty --abbrev=12)"
	echo "source:  host $(hostname) $OUT, $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null)"
	echo "steps:   $*"
	setup || { echo "setup failed"; exit 2; }
	kmark=$(date +%s%N)
	vm "echo 'gc573-live: $kmark' | sudo tee /dev/kmsg >/dev/null"
	kml reset
	load || { echo "cannot load the module"; exit 2; }
	echo "module:  srcversion $(vm "cat /sys/module/gc573/srcversion") loaded, $(vm "modinfo -F srcversion $VMDIR/gc573.ko") in ~/$VMDIR, $vdev"
	for s in "$@"; do
		echo
		echo "## $s"
		"step_$s"
	done
	echo
	echo "## test source"
	testsrc_check
	echo
	echo "## kernel log"
	kmsg_check
	kml report
	echo
	echo "## summary"
	printf '%s\n' "${results[@]}"
	echo "SUMMARY pass=$npass fail=$nfail skip=$nskip"
} 2>&1 | tee "$log"
echo "log: ${log#"$ROOT"/}"
