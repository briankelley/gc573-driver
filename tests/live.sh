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
#   change    input change while streaming: SOURCE_CHANGE, DQBUF error, no
#             DMA outside the queued images, restart at the new timings
#   loss      output off and on, idle and while streaming
#   colour    RGB limited range, YCbCr 4:4:4, YCbCr 4:2:2 (report only)
#   audio     avsync.sh on HDMI audio: 10 s capture, a burst a second,
#             left 1 kHz and right 2 kHz (channel order, rate), 48 kHz
#             against the clock, no gap, no overrun (live-av.py)
#   avsync    GC573_AV_SECS (600) of audio and video together: no overrun,
#             no gap, the driver's period counters clean, and the A/V
#             offset (flash frame vs burst onset) with its drift
#   audioloss one audio capture across 5 video stream start/stops, an input
#             loss while video streams, relock, video again, an idle loss
#             and relock: no overrun, never stalled, no gap (the driver
#             fills the video stops' and the losses' gaps), bursts with the
#             right channels after the last relock
#   unload    unload while streaming video and audio
#   reload    GC573_RELOADS (50) unload/load cycles with the source active
#   compliance  v4l2-compliance -s with the live input
# Prints RESULT lines and a SUMMARY; log: tests/logs/<UTC>_<kernel>_live.log.
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

vm() {
	ssh -n -o BatchMode=yes -o ControlMaster=auto -o ControlPath="$SSHCTL" \
		-o ControlPersist=120 "$VM" "$@"
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
src_on() { "$ROOT/tools/testsrc/show.sh" "$OUT" "$1" "$2" >/dev/null; }
src_off() { xrandr --output "$OUT" --off; }

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
		"$ROOT/tools/testsrc/avsync.sh" "$OUT" 1920x1080 60 >/dev/null 2>&1 &&
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
		"$ROOT/tests/live-compare.py" "$ROOT/tests/live-av.py" "$VM:$W/"
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

# Stream (cap -X), then run the host action $3... after 4 s; $1: tag,
# $2: "-r" to restart at the new timings afterwards, or "" (no input left)
change_while_streaming() {
	local tag=$1 rs=$2 out
	shift 2
	vm "sudo $W/gc573-cap -d $vdev -f YUYV -b 4 -n 60 -X 20 $rs -D $dbgdir/video" \
		> /tmp/gc573-live-x.txt 2>&1 &
	local p=$!
	sleep 4
	"$@" >/dev/null
	wait $p
	local rc=$?
	out=$(cat /tmp/gc573-live-x.txt)
	echo "$out" | grep -E '^(INFO change|RESULT|FAIL|LOCK)|stream:|stats:' | sed 's/^/  /'
	check "$tag" "$rc" "($(echo "$out" | sed -n 's/^RESULT change //p')${rs:+; restart: $(echo "$out" | grep '^RESULT capture ' | grep -oE 'fmt=[^ ]+ [0-9x]+ frames=[0-9]+')})"
}

step_change() {
	src_on 1920x1080 60
	time_to_lock 10 >/dev/null
	change_while_streaming change-1080p60-to-720p60 -r src_on 1280x720 60
	change_while_streaming change-720p60-to-1080p60 -r src_on 1920x1080 60
	change_while_streaming change-1080p60-to-p59.94 -r src_on 1920x1080 59.94
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
	# live stream, then the output goes off: stopped with an event
	change_while_streaming loss-streaming "" src_off
	# free-running stream (no input), then the output comes back: the
	# lock stops it with an event, restart at the input's timings
	wait_unlocked
	change_while_streaming loss-return-streaming -r src_on 1920x1080 60
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
		nvidia-settings --no-write-config -a "[DPY:$OUT]/ColorSpace=$cs" \
			-a "[DPY:$OUT]/ColorRange=$cr" >/dev/null 2>&1
		sleep 2
		settle
		hdmi_dbg | grep -E '^(it6805: mode|splitter: avi|input:)' | sed 's/^/  /'
		avi_check "colour-$name"
		live_capture "colour-$name" 60 1920x1080 60
		result "colour-$name-note" SKIP "(report only, not gating)"
	done
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
	# input loss while video streams (the driver stops the stream), relock
	change_while_streaming audioloss-video-loss "" src_off
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
	check audioloss-restarts "$([ "$(( $(aud_stat "$d1" restarts) - $(aud_stat "$d0" restarts) ))" -ge 7 ] &&
		[ "$(aud_stat "$d1" stop_missing)" = "$(aud_stat "$d0" stop_missing)" ]; echo $?)" \
		"($(( $(aud_stat "$d1" restarts) - $(aud_stat "$d0" restarts) )) DMA restarts for 7 video stops, $(( $(aud_stat "$d1" pauses) - $(aud_stat "$d0" pauses) )) pauses (input loss), $(( $(aud_stat "$d1" filled) - $(aud_stat "$d0" filled) )) frames filled)"
	# never stalled: no read more than 250 ms after the one before (a domain
	# reset, 3 x 30 ms and more, holds the periods up once per video stop)
	out=$(vm "awk '/^A /{ split(\$4, t, \"=\"); if (p && t[2] - p > m) m = t[2] - p; p = t[2] } END { printf \"%.1f\", m / 1e6 }' $W/aloss.txt")
	check audioloss-stall "$(awk -v m="$out" 'BEGIN { exit !(m < 250) }'; echo $?)" "(longest time between reads $out ms)"
	out=$(vm "python3 $W/live-av.py $W/aloss.txt $W/aloss.raw --tail 20")
	# the video stops' gaps and the input losses' pauses are filled: the
	# stream keeps time through all of them
	av_results audioloss "$(grep -E '^RESULT (tail|channels|xruns|rate|gaps) ' <<< "$out")"
	grep -E '^RESULT bursts ' <<< "$out" | sed 's/^RESULT/  info:/'
	av_off
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
all+=" unload reload compliance"
[ $# -gt 0 ] || set -- $all
krel=$(vm uname -r) || exit 2
stamp=$(date -u +%Y%m%d-%H%M%S)
log=$ROOT/tests/logs/${stamp}_${krel}_live.log
mkdir -p "$ROOT/tests/logs"
trap '"$ROOT/tools/testsrc/show.sh" --off; "$ROOT/tools/testsrc/avsync.sh" --off
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
	echo "module:  $(vm "modinfo -F srcversion $VMDIR/gc573.ko"), $vdev"
	for s in "$@"; do
		echo
		echo "## $s"
		"step_$s"
	done
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
