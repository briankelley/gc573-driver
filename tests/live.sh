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
#             1000/1001 flag at 59.94) within LOCK_MS (4 s) of the mode
#             switch;
#             POWER_PRESENT = 1; SOURCE_CHANGE on lock, loss and mode change
#   relock    GC573_RELOCKS (25) x 2 mode switches 1080p60 <-> 1080p59.94
#             with show.sh: each locks to the new rate within LOCK_MS
#   fpgawait  the lock policy with the FPGA's input measurement held not
#             valid (module parameter exp_fpga_invalid, the boot race of
#             2026-11-25): no lock and one warning while it is not valid;
#             once valid, one lock at the FPGA's rate, also when it becomes
#             valid 30 polls after the input's stable entry; the self-heal
#             off for the step (VM only)
#   fpgaheal  the self-heal of a measurement that stays not valid (the same
#             parameter; spec/hdmi-chips.md "Lock policy"): valid after
#             the first attempt, one receiver restart 90 polls in and the
#             lock, the source seeing no hot-plug; never valid, a restart
#             and two hot-plugs at least 20 and 80 s apart, one warning,
#             nothing more in 30 s, and the lock once valid; with fpga_heal
#             0 no attempt, and with 1 again the restart and the lock. The
#             output on without a test player (VM only)
#   capture   1080p60 and 1080p59.94, 6 formats x GC573_LIVE_FRAMES (600):
#             each format's last frame compared with pattern.py, all frames
#             identical (full-frame hash), no sequence gaps, G_PARM equal
#             to the DV timings' nominal interval (1/60 below 59.5 Hz: the
#             card delivers those at 60 Hz), mean interval within 0.1 % of
#             the interval G_PARM reports, first frame dropped
#   modes     every mode the GPU offers for the output (the card's EDID;
#             1080p60 last, as the way back), each entered from another:
#             the lock with the FPGA's measurement valid within 40 polls
#             (fpga_waits unchanged; the polls it took), the DV timings
#             and their rate against the mode's, and a verified capture
#             (GC573_MODE_FRAMES, 120, per format: 2 s at the card's
#             delivery rate, which is 60 Hz below 59.94)
#   change    input change while streaming: SOURCE_CHANGE, no DMA outside
#             the queued images; to other timings a DQBUF error and a
#             restart at the new timings; 60 -> 59.94 Hz (same buffers) the
#             stream carries on; an application that never sets timings
#             gets the new ones once its queue is free
#   blip      a short lock in other timings while streaming (a GPU after a
#             hot-plug shows its preferred mode before the desktop sets its
#             own): 1080p60 -> 720p60, and back as soon as the driver locks
#             at 720p. The stream carries on (no DQBUF error, frames after
#             the events) and the driver counts a hold, no stop. Then 720p60
#             for good: the DQBUF error comes when the hold ends, 0.9-1.6 s
#             after the lock
#   loss      output off and on, idle and while streaming: the stream
#             carries on, black while off, the pattern again after;
#             TRY_FMT and G_FMT keep the colorimetry of the input that
#             locked, idle and streaming
#   colour    RGB limited range, YCbCr 4:4:4, YCbCr 4:2:2 (report only)
#   colorimetry  TRY_FMT and G_FMT follow the last input that locked
#             (spec/hdmi-chips.md "Stream policy on input changes"): RGB
#             full, YCbCr 4:4:4 limited, RGB limited (each switched at its
#             lock), a loss and the relock in RGB limited (kept), RGB full;
#             720x480 RGB (BT.601 by size) through a loss while streaming:
#             the format kept, the frames black. The output's colour only,
#             at runtime, put back to RGB full range on every exit (VM only)
#   audio     avsync.sh on HDMI audio: 10 s capture, a burst a second,
#             left 1 kHz and right 2 kHz (channel order, rate), 48 kHz
#             against the clock, no gap, no overrun (live-av.py)
#   exact     frame by frame: GC573_EXACT_SECS (60) of gc573-aud -V -P per
#             source, show.sh --counter at 1080p60 and avsync.sh --pattern
#             at 1080p60, 1080p59.94 and 720p59.94. FAIL only on a loss of
#             the driver's: a sequence gap, or a frame interval outside half
#             to one and a half periods (live-av.py --exact). The counter's
#             repeats, skips and tears between regular frames are the
#             source's (its player against the display's refresh): INFO,
#             with the net slip against what the two clocks predict, and
#             SOURCE BROKEN when it misses that by more than 1.5 frames
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
#             s; memory, CPU, the recording (not in the default steps).
#             GC573_OBSSOAK_INJECT=T:MODE:RATE adds an outside change T s in
#             (obs-events.py soak --inject: a trial of the recovery)
#   soak      GC573_SOAK_SECS (7200) of audio and video (1080p60 YUYV)
#             together with avsync.sh, as avsync, and every minute the
#             kernel's memory (MemAvailable, Slab, SUnreclaim) and the CPU
#             time of the capture and of the driver's IRQ thread: memory
#             stable, CPU use reported (not in the default steps)
#   apps      ffmpeg, GStreamer and VLC (each present; GStreamer not on the
#             host): captures checked against the pattern, the audio and
#             the A/V offset, and each source change with what the app did
#             and what brings it back (step_apps; not in the default steps)
#   unload    unload while streaming video and audio
#   reload    GC573_RELOADS (50) unload/load cycles with the source active
#   compliance  v4l2-compliance -s with the live input
# Host-local mode (GC573_LOCAL=1, or VM=local): the driver runs on this
# machine, bound by the user (tools/install.sh), and the checks run here
# with no ssh. live.sh then never loads, unloads, binds or unbinds the
# driver (vm() refuses such commands, and the module must be bound already),
# never changes the GPU's colour settings, and leaves OBS's configuration as
# the user has it: only the steps in LOCAL_STEPS run (default: those up to
# audioloss without colour, and compliance; obssoak and soak on request).
# obssoak, host form: GC573_OBSSOAK_ROTATION (default: output off/on, 60 <->
# 59.94 Hz, 1080p <-> 720p with OBS's reopen, EDID re-sets), the recording
# in GC573_REC_DIR (default ~/gc573-rec, deleted after the analysis), OBS
# started minimized (tests/obs-run.sh --keep-config) with the sources
# checked, not set up (tests/obs-check.py verify: setting them up would make
# OBS open every /dev/video* node, cameras too), and the driver's own A/V
# offset (gc573-aud -V -P) in the source sessions of the first and last
# segments. sudo: SUDO_ASKPASS (sudo -A), else cached credentials (sudo -n).
# GC573_OBS_BUFFERING defaults to 0 here, the README's recommendation.
# GC573_OBS_BRIDGE=0: obsevents and obssoak without tests/obsbridge.py (the
# reopen from the input's timings; default on).
# Roku mode (GC573_SOURCE=roku, host-local only; M6): the source is the
# Roku through the HDCP filter, driven by tools/roku/ecp.py, playing
# tools/roku/pattern-video.sh's file from tools/roku/serve.py. DVI-D-0 is
# never touched (src_on, src_off, av_on and colour_set refuse). Actions on
# the Roku need GC573_ROKU_GO=1; without it only rokuwhich, rokulock,
# rokucompliance, q25 and q25back run, passively. On the saved Roku they
# also need it identified as the cabled one (rokuwhich; tools/roku/ecp.py
# refuses otherwise), and its first action saves its state for the record
# (the app in the foreground, the power mode: 0600, never logged). The
# run's end does not restore it (the user does): it only stops our video
# if it still plays, and Home if its PowerOff left the Roku asleep. Steps
# without our pattern (any picture; the driver's verdict from its own
# numbers: sequence numbers, frame intervals, counters) and with it (Play on
# Roku). Default: rokulock rokucompliance rokusleep rokumodes rokuobsany.
#   rokuwhich is the saved Roku the cabled one? Passive, the saved Roku
#             alone asked (no SSDP): its ui-resolution follows a 720p-only
#             EDID and back
#   rokuwhichkey  (the go) the fallback: Info, then Back, on the Roku that
#             is on, and whether the card's picture changed with it
#   rokulock  the input locks; timings, colour and range; model, software
#   rokucompliance  v4l2-compliance -s with the Roku's input
#   rokucapture  GC573_ROKU_SECS (60) of the pattern video: the driver loses
#             nothing (live-av.py --exact), the bursts' channels and the A/V
#             offset, the colour patches against BT.709 limited range
#   rokuobs   OBS on the Roku's pattern: screenshots, meters, a recording
#   rokusleep (any picture) PowerOff, then Home: what the card sees at each
#             step, the lock after Home, 10 s of gc573-aud -V before and after
#   rokumodes (any picture) EDID re-sets (720p only, another serial, the
#             default): the Roku's mode after each hot-plug (INFO when it
#             does not follow), the lock, 10 s of gc573-aud -V
#   rokustart (any picture) streams started at a fresh 720p or 1080p lock:
#             every interval within 10 % of IN_FRAME_PERIOD, the first 40 at
#             its rate (the delivery settle); untouched blocks, band
#             signatures, the ring, the HDMI worker
#   rokurelock  (any picture) a stream across a same-timings relock: the
#             same checks from the driver's live restart on
#   rokuobsany  (any picture) OBS: screenshots, meters, a 60 s recording
#             (deleted), the driver's stream, intervals and counters
#   rokureboot  the Roku restarted (GC573_ROKU_REBOOT_KEYS: ECP has no
#             command for it): the input back within 3 minutes
#   rokuobssoak  obssoak with the Roku's pattern and the Roku's changes
#   rokusoakany  (any picture) the 2-hour soak without playback: OBS records
#             while the Roku sleeps and wakes, the EDID is set again and OBS
#             reopens its devices; the driver's stream, intervals, counters
#             and memory, OBS's counters and log
#   q25       open question 25, the Roku without the filter: what the driver
#             reports over GC573_Q25_SECS (180), the self-heal's lines, a
#             capture that neither hangs nor delivers garbage (the unbind
#             is the coordinator's)
#   q25back   the filter back: the lock without a reload, and the pattern
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
EXACT_SECS=${GC573_EXACT_SECS:-60}
OBS_SECS=${GC573_OBS_SECS:-600}
OBSEV_REPS=${GC573_OBSEV_REPS:-2}
LOCAL=0
{ [ "${GC573_LOCAL:-0}" = 1 ] || [ "$VM" = local ]; } && LOCAL=1
SOURCE=${GC573_SOURCE:-pc}
case $SOURCE in
pc) ;;
roku) [ "$LOCAL" = 1 ] || { echo "GC573_SOURCE=roku: host-local only (GC573_LOCAL=1)"; exit 2; } ;;
*) echo "GC573_SOURCE: pc or roku"; exit 2 ;;
esac
OBS_BUFFERING=${GC573_OBS_BUFFERING:-$((1 - LOCAL))}
OBSSOAK_SECS=${GC573_OBSSOAK_SECS:-7200}
OBSSOAK_EVERY=${GC573_OBSSOAK_EVERY:-180}
OBSSOAK_INJECT=${GC573_OBSSOAK_INJECT:-}
OBSEV_ARGS=()
[ "${GC573_OBS_BRIDGE:-1}" = 1 ] || OBSEV_ARGS+=(--no-bridge)
SOAK_SECS=${GC573_SOAK_SECS:-7200}
PW_SECS=${GC573_PW_SECS:-120}
# tools/devvm: keeps PipeWire (ACP_IGNORE) and PulseAudio off the card
PW_RULE=/etc/udev/rules.d/90-gc573-pulse-ignore.rules
# obspw's WirePlumber rule (the desktop user's config, removed after it)
PW_WP=.config/wireplumber/main.lua.d/51-gc573-obspw.lua
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=/tmp/gc573-live		# work directory in the VM (here, in local mode)
# local mode: the steps that leave the driver's binding, the GPU's colour
# settings and OBS's configuration alone
LOCAL_STEPS="bringup lock relock capture modes change blip loss audio exact avsync audioloss soak obssoak apps compliance"
REC_DIR=${GC573_REC_DIR:-$HOME/gc573-rec}
OBSSOAK_ROTATION=${GC573_OBSSOAK_ROTATION:-sleep,rate-59.94,edid-same,rate-60,res-720p,edid-new,sleep,res-1080p,edid-default}
if [ "$LOCAL" = 1 ]; then
	VM=local
	VMDIR=$ROOT
	export GC573_VM=local	# tests/obs-events.py: the driver's side here too
	if [ -n "${SUDO_ASKPASS:-}" ]; then LOCAL_SUDO='sudo() { command sudo -A "$@"; }; '
	else LOCAL_SUDO='sudo() { command sudo -n "$@"; }; '; fi
fi
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
# shellcheck source=tools/testsrc/scrub.sh
. "$ROOT/tools/testsrc/scrub.sh"	# gc573_scrub: no USB serial in a log
ev() { [ -z "${GC573_EVENT_LOG:-}" ] || echo "$(date -u +%FT%T.%3NZ) live $(gc573_scrub "$*")" >> "$GC573_EVENT_LOG"; }
vm() {
	local what="" rc
	if [ "$LOCAL" = 1 ]; then
		case "$*" in
		*rmmod*|*insmod*|*modprobe*|*/unbind*|*/bind*|*drivers_probe*|*driverctl*|*install.sh*)
			echo "live.sh: not on this host (the driver's binding is the user's): $*" >&2
			ev "refused on the host: $(head -c 120 <<< "$*" | tr '\n\t' '  ')"
			return 1 ;;
		esac
	fi
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
	if [ "$LOCAL" = 1 ]; then
		bash -c "$LOCAL_SUDO$*" < /dev/null
	else
		ssh -n -o BatchMode=yes -o ControlMaster=auto -o ControlPath="$SSHCTL" \
			-o ControlPersist=120 "$VM" "$@"
	fi
	rc=$?
	[ "$what" != stream ] || ev "stream stop (exit $rc)"
	return $rc
}
# put FILE... DIR: copy files to DIR in the VM (here, in local mode)
put() {
	if [ "$LOCAL" = 1 ]; then
		cp "${@:1:$#-1}" "${!#}"
	else
		scp -q -o ControlPath="$SSHCTL" "${@:1:$#-1}" "$VM:${!#}"
	fi
}
vdev="" dbgdir="" pcm=hw:none
# the card's video node by its by-path name (the host's rules: every tool
# gets -d with it, never a bare /dev/videoN), checked against sysfs; the
# PCM by its control node's by-path name, from the same PCI device. Never
# by the card's id: alsa-lib finds hw:CARD=GC573 by opening the control
# node of every card before it to compare ids (snd_card_get_index), a
# webcam's among them (the breach in
# tests/logs/20261126-031656_6.8.0-151-generic_live-events.log). A path
# (or an index) it opens alone.
find_vdev() {
	local bdf node card
	bdf=$(vm "basename \$(readlink -f /sys/bus/pci/drivers/gc573/0000:*)" 2>/dev/null)
	node=$(vm "ls /sys/bus/pci/drivers/gc573/$bdf/video4linux/ 2>/dev/null" | head -1)
	card=$(vm "ls -d /sys/bus/pci/drivers/gc573/$bdf/sound/card[0-9]* 2>/dev/null" | head -1)
	vdev=/dev/v4l/by-path/pci-$bdf-video-index0
	dbgdir=/sys/kernel/debug/gc573-$bdf
	pcm=hw:none
	[ -n "$card" ] && [ "$(vm "readlink -f /dev/snd/by-path/pci-$bdf")" = "/dev/snd/controlC${card##*/card}" ] &&
		pcm=hw:CARD=/dev/snd/by-path/pci-$bdf,DEV=0
	[ -n "$node" ] && [ "$(vm "readlink -f $vdev")" = "/dev/$node" ]
}
cap() { vm "sudo $W/gc573-cap -d $vdev -D $dbgdir/video $*"; }
query() { vm "v4l2-ctl -d $vdev --query-dv-timings" 2>&1; }
locked() { vm "v4l2-ctl -d $vdev --query-dv-timings >/dev/null 2>&1"; }
hdmi_dbg() { vm "sudo cat $dbgdir/hdmi"; }
aud_dbg() { vm "sudo cat $dbgdir/audio"; }
aud() { vm "sudo $W/gc573-aud -D $pcm $*"; }

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
	if [ "$LOCAL" = 1 ]; then
		grep -q '^gc573 ' /proc/modules && find_vdev && return 0
		echo "gc573 is not bound on this host: live.sh does not load it here (tools/install.sh)"
		return 1
	fi
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
	put "$ROOT/tools/testsrc/pattern.py" \
		"$ROOT/tests/live-compare.py" "$ROOT/tests/live-av.py" \
		"$ROOT/tests/obsws.py" "$ROOT/tests/obs-check.py" \
		"$ROOT/tests/obs-av.py" "$ROOT/tests/obs-run.sh" "$ROOT/tests/obs-events.py" \
		"$ROOT/tests/obsbridge.py" "$ROOT/tests/app-check.py" "$W/"
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
# The input rate the DV timings in a LOCK line ($1) give, in Hz: the pixel
# clock over the frame, x 1000/1001 with REDUCED_FPS (not G_PARM's 1/60)
dv_rate() {
	python3 - "$1" <<'EOF'
import re, sys
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
print(f"{d / n:.4f}")
EOF
}
# a DV rate ($1) is the mode's rate ($2, xrandr's two decimals): within
# its rounding and 0.02 %, so 60 and 59.94, 24 and 23.98 stay apart
rate_is() {
	awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; t = 0.005 + b * 0.0002
		exit !(d <= t && -d <= t) }'
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
	local dvr
	dvr=$(dv_rate "$lock")
	check "$tag-timings" "$([ "${w}x$h" = "$size" ] && rate_is "$dvr" "$rate"; echo $?)" \
		"(${w}x$h at $dvr Hz in the DV timings, delivered at $fps Hz; expected $size at $rate)"
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

# the longest a lock may take from the output on or a mode switch: 1.6-1.9 s
# measured before the delivery settle (spec/hdmi-chips.md "Lock policy"),
# which publishes a lock no earlier than 1.25 s after the stable entry,
# about 1 s later than before
LOCK_MS=${GC573_LOCK_MS:-4000}
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
		[ "$t" -le "$LOCK_MS" ]; echo $?)" "($t ms from output on, at most $LOCK_MS)"
	t0=$(date +%s%N)
	src_on 1920x1080 59.94
	wait_unlocked
	time_to_lock 10 >/dev/null
	t=$(( ($(date +%s%N) - t0) / 1000000 ))
	q=$(query)
	echo "$q" | sed 's/^/  /'
	check lock-1080p59.94 "$(cta1080p60 "$q" && grep -q 'framerate is reduced by 1/1.001' <<< "$q" &&
		[ "$t" -le "$LOCK_MS" ]; echo $?)" "($t ms from the mode switch, at most $LOCK_MS)"
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
			[ "$ms" -le "$LOCK_MS" ] || bad=$((bad + 1))
		done
	done
	echo "  ms from the switch to the new rate:$times"
	check relock "$([ $bad = 0 ]; echo $?)" \
		"($((n - bad)) of $n switches locked within $LOCK_MS ms, slowest $tmax ms; $(hdmi_dbg | grep -oE '(level_changes|fpga_rejects) [0-9]+' | tr '\n' ' '))"
}

# fpgawait: the lock policy (spec/hdmi-chips.md "Lock policy") with the
# FPGA's input measurement held not valid by the experiment parameter
# exp_fpga_invalid: for that many polls after each stable entry the driver
# sees 0x1004[1:0] = 1, as a host boot did on 2026-11-25 (the lock then
# came from the IT6805's clock: 59.32 Hz for 1080p60), and 0x1010 = 0
FPGA_PARAM=/sys/module/gc573/parameters/exp_fpga_invalid
fpga_param() { vm "echo $1 | sudo tee $FPGA_PARAM > /dev/null"; }
kmsg_mark() { vm "echo 'gc573-live: $1' | sudo tee /dev/kmsg > /dev/null"; }
# KMSG_BAD and KMSG_DRV_BAD as tests/lib.sh has them, without sourcing it:
# its kmsg_mark and kmsg_since (run.sh's, as root where the driver runs)
# would replace live.sh's for the rest of the run, and it runs lspci
lib_kmsg_patterns() {
	local GC573_MOD=gc573
	eval "$(grep -E '^KMSG_(DRV_)?BAD\+?=' "$ROOT/tests/lib.sh")"
}
# the kernel log after the LAST mark $1 (nothing without one): a step that
# runs twice in one boot (fpgawait for two modules) writes each mark twice
kmsg_since() {
	vm "sudo dmesg | awk -v m='gc573-live: $1' 'index(\$0, m) { n = NR } { l[NR] = \$0 }
		END { if (n) for (i = n + 1; i <= NR; i++) print l[i] }'"
}
fpga_waits() { hdmi_dbg | grep -oE 'fpga_waits [0-9]+' | cut -d' ' -f2; }
lock_lines() { grep -c 'HDMI: locked' <<< "$1"; }
lock_rates() { grep -oE 'frame period [0-9a-fx]+ \([0-9.]+ Hz\)' <<< "$1" | paste -sd, - | sed 's/,/, /g'; }
step_fpgawait() {
	local line log w0 w1 q t i h0
	if ! vm "test -e $FPGA_PARAM"; then
		result fpgawait SKIP "(the loaded gc573 has no exp_fpga_invalid)"
		return
	fi
	# the lock policy alone: the self-heal (fpgaheal) off for the step, or
	# its restart 90 polls in could come before the measurement is valid
	h0=$(vm "cat $HEAL_PARAM" 2>/dev/null)
	[ -z "$h0" ] || heal_param 0
	src_on 1920x1080 60
	time_to_lock 10 > /dev/null
	w0=$(fpga_waits)
	# never valid: no lock however long, and the warning after 40 polls
	fpga_param 4294967295
	src_off
	wait_unlocked
	kmsg_mark fpgawait-never
	src_on 1920x1080 60
	for i in $(seq 100); do
		kmsg_since fpgawait-never | grep -q 'the FPGA has no valid measurement' && break
		sleep 0.1
	done
	sleep 1
	line=$(hdmi_dbg | grep '^input:')
	log=$(kmsg_since fpgawait-never | grep gc573)
	w1=$(fpga_waits)
	grep 'HDMI: ' <<< "$log" | sed 's/^/  | /'
	echo "  $line"
	check fpgawait-no-lock "$(grep -q 'signal 1 locked 0' <<< "$line" && ! locked &&
		[ "$(lock_lines "$log")" = 0 ]; echo $?)" \
		"(the FPGA measurement held not valid for good: $(grep -oE 'locked [01] period [0-9a-fx]+' <<< "$line"), QUERY_DV_TIMINGS $(locked && echo locked || echo 'no lock'), $(lock_lines "$log") lock lines${log:+: $(lock_rates "$log")})"
	check fpgawait-warning "$([ "$(grep -c 'the FPGA has no valid measurement' <<< "$log")" = 1 ] &&
		[ -n "$w0" ] && [ "${w1:-}" = $((w0 + 1)) ]; echo $?)" \
		"(the warning once: $(grep -c 'the FPGA has no valid measurement' <<< "$log"); fpga_waits ${w0:-none} -> ${w1:-none})"
	# valid again: the lock within a few polls, at the FPGA's rate
	kmsg_mark fpgawait-valid
	fpga_param 0
	t=$(time_to_lock 3)
	q=$(query)
	sleep 1
	log=$(kmsg_since fpgawait-valid | grep 'HDMI: locked')
	echo "$log" | sed 's/^/  | /'
	check fpgawait-lock "$([ "$t" != none ] && cta1080p60 "$q" && ! grep -q 'framerate is reduced' <<< "$q" &&
		[ "$(lock_lines "$log")" = 1 ] && ! grep -q 'frame period 0 ' <<< "$log"; echo $?)" \
		"(the measurement valid again: locked after $t ms; $(lock_lines "$log") lock lines: $(lock_rates "$log"))"
	# valid 30 polls (1.7 s) after the stable entry, a slow start: one lock,
	# at the FPGA's rate
	fpga_param 30
	src_off
	wait_unlocked
	kmsg_mark fpgawait-late
	src_on 1920x1080 60
	t=$(time_to_lock 10)
	sleep 3
	fpga_param 0
	q=$(query)
	log=$(kmsg_since fpgawait-late | grep 'HDMI: locked')
	echo "$log" | sed 's/^/  | /'
	check fpgawait-late "$([ "$t" != none ] && cta1080p60 "$q" && [ "$(lock_lines "$log")" = 1 ] &&
		! grep -q 'frame period 0 ' <<< "$log"; echo $?)" \
		"(the measurement valid 30 polls after the stable entry: locked $t ms after the output came on; $(lock_lines "$log") lock lines: $(lock_rates "$log"))"
	[ -z "$h0" ] || heal_param "$h0"
}

# fpgaheal: the measurement self-heal (spec/hdmi-chips.md "Lock policy",
# open question 40). exp_fpga_invalid holds the FPGA's measurement not
# valid, as at the boot race: 4294967294 until the self-heal's first attempt
# (a case the receiver restart fixes), 4294967295 for good (a case nothing
# fixes). The module parameter fpga_heal turns the self-heal off. What the
# source sees: monitor_present in the ELD of the card's port (/proc/asound,
# as tests/hpd-unload.sh), every 50 ms. The output stays on without a test
# player: the self-heal's hot-plugs can drop its mode (as vm() does for an
# EDID set). A driver without the self-heal fails every case (no SKIP):
# they are its failing-before test.
HEAL_PARAM=/sys/module/gc573/parameters/fpga_heal
heal_param() { vm "echo $1 | sudo tee $HEAL_PARAM > /dev/null"; }
# "heals fixes giveups" from debugfs hdmi; empty without the self-heal
heal_counts() {
	hdmi_dbg | sed -nE 's/.* fpga_heals ([0-9]+) fpga_heal_fixes ([0-9]+) fpga_heal_giveups ([0-9]+).*/\1 \2 \3/p'
}
heal_delta() {	# two heal_counts: the change, or "none"
	[ -n "$1" ] && [ -n "$2" ] || { echo none; return; }
	# shellcheck disable=SC2086 # the six numbers
	set -- $1 $2
	echo "$(($4 - $1)) $(($5 - $2)) $(($6 - $3))"
}
heal_eld="" heal_eld_log="" heal_eld_pid="" heal_c0="" heal_5v="" heal_probe=""
heal_eld_start() {
	heal_eld_log=$(mktemp)
	[ -n "$heal_eld" ] || return 0
	(
		p=1
		while kill -0 $$ 2>/dev/null; do
			m=
			while read -r k v; do
				[ "$k" = monitor_present ] && m=$v
			done < "$heal_eld"
			[ "$m" = "$p" ] || { echo "$(date -u +%T.%3N) monitor_present $m" >> "$heal_eld_log"; p=$m; }
			sleep 0.05
		done
	) &
	heal_eld_pid=$!
}
heal_eld_stop() {	# the drops of monitor_present since the start, or "unknown"
	if [ -n "$heal_eld_pid" ]; then
		kill "$heal_eld_pid" 2>/dev/null
		wait "$heal_eld_pid" 2>/dev/null
	fi
	heal_eld_pid=
	if [ -n "$heal_eld" ]; then grep -c 'monitor_present 0' "$heal_eld_log"; else echo unknown; fi
	rm -f "$heal_eld_log"
}
# the output on in a mode, without a test player
src_bare() {
	src_on "$1" "$2"
	"$ROOT/tools/testsrc/show.sh" --off
}
# kernel log $1: the seconds of the "self-heal N of" and "gave up" lines
heal_times() {
	sed -nE 's/^\[ *([0-9.]+)\].*HDMI: self-heal ([0-9] of|gave up).*/\1/p' <<< "$1" | paste -sd' ' -
}
heal_attempts() { grep -oE 'self-heal [0-9] of [0-9], [a-z -]+' <<< "$1" | paste -sd';' - | sed 's/;/; /g'; }
# Through a case, in the VM as root: every 50 ms the splitter's 5 V state
# (debugfs hdmi "rx 5v" and the published power, RX 0x13 bit 0), each
# change logged: does the source drop 5 V at a hot-plug's HPD low (the
# self-heal's 10 s quiet guard)? And a second handle's QUERY_DV_TIMINGS,
# G_FMT and G_EDID about 5 times a second, with their times: G_EDID waits
# for h->lock, which a hot-plug holds for RD's 500 ms toggle; the other two
# do not take it. Nothing may fail or hang.
heal_watch_start() {
	local f
	f=$(mktemp)
	cat > "$f" <<-EOF
	( p=
	while [ -e $W/heal.run ]; do
		v=\$(grep -oE 'rx 5v [01]|^input: power [01]' $dbgdir/hdmi | tr '\n' ' ')
		[ "\$v" = "\$p" ] || { echo "\$(date -u +%T.%3N) \$v"; p=\$v; }
		sleep 0.05
	done > $W/heal-5v.log ) &
	while [ -e $W/heal.run ]; do
		t0=\$(date +%s%N)
		v4l2-ctl -d $vdev --query-dv-timings > /dev/null 2>&1; a=\$?
		t1=\$(date +%s%N)
		v4l2-ctl -d $vdev --get-fmt-video > /dev/null 2>&1; b=\$?
		t2=\$(date +%s%N)
		v4l2-ctl -d $vdev --get-edid=format=raw > /dev/null 2>&1; c=\$?
		t3=\$(date +%s%N)
		echo "\$(((t1 - t0) / 1000000)) \$a \$(((t2 - t1) / 1000000)) \$b \$(((t3 - t2) / 1000000)) \$c"
		sleep 0.1
	done > $W/heal-probe.log
	wait
	EOF
	put "$f" "$W/heal-watch.sh"
	rm -f "$f"
	vm "touch $W/heal.run; sudo sh $W/heal-watch.sh > /dev/null 2>&1 &"
}
# Sets heal_5v (the 5 V log) and heal_probe ("rounds qdv_max fmt_max
# edid_max fmt_failed edid_failed locked")
heal_watch_stop() {
	vm "rm -f $W/heal.run"
	sleep 1
	heal_5v=$(vm "cat $W/heal-5v.log")
	heal_probe=$(vm "awk '{ n++; for (i = 1; i <= 5; i += 2) if (\$i > m[i]) m[i] = \$i
		if (\$4) f++; if (\$6) g++; if (!\$2) l++ }
		END { print n + 0, m[1] + 0, m[3] + 0, m[5] + 0, f + 0, g + 0, l + 0 }' $W/heal-probe.log")
}
# the probe's summary, and whether nothing failed and nothing waited long:
# QUERY_DV_TIMINGS and G_FMT under 500 ms, G_EDID under 1500 ms
heal_probe_text() {
	# shellcheck disable=SC2086 # the seven numbers
	set -- $heal_probe
	echo "second handle: ${1:-0} rounds, max ms QUERY_DV_TIMINGS ${2:-?}, G_FMT ${3:-?}, G_EDID ${4:-?}; failed G_FMT ${5:-?}, G_EDID ${6:-?}; locked in ${7:-?}"
}
heal_probe_ok() {
	# shellcheck disable=SC2086
	set -- $heal_probe
	[ "${1:-0}" -gt 10 ] && [ "$2" -lt 500 ] && [ "$3" -lt 500 ] && [ "$4" -lt 1500 ] &&
		[ "$5" = 0 ] && [ "$6" = 0 ]
}
heal_5v_text() {	# the changes after the first line (the state at the start)
	local n
	n=$(($(grep -c . <<< "$heal_5v") - 1))
	if [ "$n" -le 0 ]; then echo "5 V held ($(head -1 <<< "$heal_5v" | cut -d' ' -f2-))"
	else echo "5 V changed $n times: $(tail -n +2 <<< "$heal_5v" | paste -sd';' -)"; fi
}
heal_case() {	# tag exp: a stable entry with exp_fpga_invalid = exp
	src_off
	wait_unlocked
	fpga_param "$2"
	ev "fpgaheal $1: exp_fpga_invalid $2"
	kmsg_mark "fpgaheal-$1"
	heal_c0=$(heal_counts)
	src_bare 1920x1080 60
	heal_eld_start
	heal_watch_start
}
step_fpgaheal() {
	local h0 c1 d e t q log log2 times i
	if ! vm "test -e $FPGA_PARAM"; then
		result fpgaheal SKIP "(the loaded gc573 has no exp_fpga_invalid)"
		return
	fi
	h0=$(vm "cat $HEAL_PARAM" 2>/dev/null)
	[ -z "$h0" ] || heal_param 1
	src_bare 1920x1080 60
	time_to_lock 10 > /dev/null
	heal_eld=$(grep -l 'GC573' /proc/asound/card*/eld#* 2>/dev/null | head -1)
	echo "  fpga_heal ${h0:-missing}; the ELD of the card's port: ${heal_eld:-not found}"

	# 1. valid after the first attempt: one receiver restart 90 polls (about
	#    5 s) after the release, then one lock; the source sees nothing
	heal_case fixed 4294967294
	t=$(time_to_lock 20)
	sleep 1
	e=$(heal_eld_stop)
	heal_watch_stop
	q=$(query)
	c1=$(heal_counts)
	fpga_param 0
	log=$(kmsg_since fpgaheal-fixed | grep 'gc573.*HDMI: ')
	sed 's/^/  | /' <<< "$log"
	d=$(heal_delta "$heal_c0" "$c1")
	check fpgaheal-fixed "$([ "$t" != none ] && cta1080p60 "$q" &&
		[ "$(grep -c 'HDMI: self-heal 1 of 3, receiver restart: input stable for 90 polls' <<< "$log")" = 1 ] &&
		[ "$(grep -c 'HDMI: self-heal' <<< "$log")" = 1 ] &&
		grep -q 'HDMI: FPGA measurement valid after self-heal 1' <<< "$log" &&
		[ "$(lock_lines "$log")" = 1 ] && [ "$d" = "1 1 0" ] &&
		{ [ "$e" = 0 ] || [ "$e" = unknown ]; } && heal_probe_ok; echo $?)" \
		"(locked $t ms after the output came on; attempts: $(heal_attempts "$log"); $(lock_lines "$log") lock lines: $(lock_rates "$log"); heals, fixes, give-ups +$d; HPD drops the source saw: $e; $(heal_5v_text); $(heal_probe_text))"

	# 2. never valid: a restart, then two hot-plugs at least 20 and 80 s
	#    after the attempt before, one warning 5 s after the third, and no
	#    more (30 s); the lock once the measurement is valid, which ends
	#    the session uncounted
	heal_case never 4294967295
	for i in $(seq 200); do
		log=$(kmsg_since fpgaheal-never)
		grep -q 'HDMI: self-heal gave up' <<< "$log" && break
		# a driver without the self-heal: no attempt by 15 s
		[ "$i" -lt 15 ] || grep -q 'HDMI: self-heal 1 of' <<< "$log" || break
		sleep 1
	done
	grep -q 'HDMI: self-heal gave up' <<< "$log" && sleep 30
	e=$(heal_eld_stop)
	heal_watch_stop
	c1=$(heal_counts)
	log=$(kmsg_since fpgaheal-never | grep 'gc573.*HDMI: ')
	sed 's/^/  | /' <<< "$log"
	echo "  the splitter's 5 V and the published power (UTC):"
	sed 's/^/  5v | /' <<< "$heal_5v"
	times=$(heal_times "$log")
	d=$(heal_delta "$heal_c0" "$c1")
	check fpgaheal-never "$(grep -q 'HDMI: self-heal 1 of 3, receiver restart: input stable for 90 polls' <<< "$log" &&
		grep -q 'HDMI: self-heal 2 of 3, hot-plug' <<< "$log" &&
		grep -q 'HDMI: self-heal 3 of 3, hot-plug' <<< "$log" &&
		[ "$(grep -c 'HDMI: self-heal gave up after 3 attempts' <<< "$log")" = 1 ] &&
		[ "$(grep -c 'HDMI: self-heal' <<< "$log")" = 4 ] &&
		[ "$(lock_lines "$log")" = 0 ] && [ "$d" = "3 0 1" ] &&
		awk '{ exit !(NF == 4 && $2 - $1 >= 20 && $2 - $1 < 30 &&
			$3 - $2 >= 80 && $3 - $2 < 90 && $4 - $3 >= 5 && $4 - $3 < 20) }' <<< "$times" &&
		{ [ "$e" = 2 ] || [ "$e" = unknown ]; } && heal_probe_ok; echo $?)" \
		"(attempts: $(heal_attempts "$log"); at s ${times:-none} (kernel clock); $(grep -c 'HDMI: self-heal gave up' <<< "$log") warnings, nothing in the 30 s after; $(lock_lines "$log") lock lines; heals, fixes, give-ups +$d; HPD drops the source saw: $e; $(heal_5v_text), $(grep -c 'HDMI: no 5 V' <<< "$log") no-5-V lines; $(heal_probe_text))"
	kmsg_mark fpgaheal-valid
	fpga_param 0
	t=$(time_to_lock 5)
	q=$(query)
	sleep 1
	log=$(kmsg_since fpgaheal-valid | grep 'gc573.*HDMI: ')
	c1=$(heal_counts)
	d=$(heal_delta "$heal_c0" "$c1")
	check fpgaheal-never-lock "$([ "$t" != none ] && cta1080p60 "$q" && [ "$(lock_lines "$log")" = 1 ] &&
		! grep -q 'HDMI: FPGA measurement valid after self-heal' <<< "$log" &&
		[ "$d" = "3 0 1" ] && hdmi_dbg | grep -q ' heal_tries 0 '; echo $?)" \
		"(the measurement valid again: locked after $t ms, $(lock_lines "$log") lock lines: $(lock_rates "$log"); heals, fixes, give-ups +$d since the case began)"

	# 3. fpga_heal 0: no attempt and no lock for 8 s; on again: the first
	#    attempt at once (stable for more than 90 polls), then the lock
	[ -z "$h0" ] || heal_param 0
	heal_case off 4294967294
	sleep 8
	log=$(kmsg_since fpgaheal-off | grep 'gc573.*HDMI: ')
	q=$(locked && echo locked || echo 'no lock')
	kmsg_mark fpgaheal-on
	heal_param 1
	t=$(time_to_lock 5)
	sleep 1
	e=$(heal_eld_stop)
	heal_watch_stop
	c1=$(heal_counts)
	fpga_param 0
	d=$(heal_delta "$heal_c0" "$c1")
	sed 's/^/  | /' <<< "$log"
	log2=$(kmsg_since fpgaheal-on | grep 'gc573.*HDMI: ')
	sed 's/^/  | /' <<< "$log2"
	check fpgaheal-off "$([ "$q" = 'no lock' ] && ! grep -q 'HDMI: self-heal' <<< "$log" &&
		[ "$t" != none ] && grep -q 'HDMI: self-heal 1 of 3, receiver restart' <<< "$log2" &&
		[ "$(lock_lines "$log2")" = 1 ] && [ "$d" = "1 1 0" ] &&
		{ [ "$e" = 0 ] || [ "$e" = unknown ]; } && heal_probe_ok; echo $?)" \
		"(off for 8 s: $q, $(grep -c 'HDMI: self-heal' <<< "$log") attempts; on: locked after $t ms, attempts: $(heal_attempts "$log2"); heals, fixes, give-ups +$d; HPD drops the source saw: $e; $(heal_5v_text); $(heal_probe_text))"
	[ -z "$h0" ] || heal_param "$h0"
	src_on 1920x1080 60
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

# the FPGA counters in debugfs hdmi: "rejects waits" (polls of a stable
# input whose measurement was not valid before a lock; warnings)
fpga_counts() {
	hdmi_dbg | sed -nE 's/.* fpga_rejects ([0-9]+) fpga_waits ([0-9]+).*/\1 \2/p'
}
mode_lock() {	# tag mode rate: enter the mode, then the lock checks
	local tag=$1 m=$2 r=$3 c0 c1 t q d dvr
	c0=$(fpga_counts)
	src_on "$m" "$r"
	t=$(time_to_lock 15)
	c1=$(fpga_counts)
	d=$((${c1% *} - ${c0% *}))
	check "$tag-lock" "$([ "$t" != none ] && [ "${c1#* }" = "${c0#* }" ] && [ "$d" -lt 40 ]; echo $?)" \
		"(locked ${t} ms after show.sh; the FPGA's measurement not yet valid for $d polls of the stable input, the warning at 40: fpga_waits ${c0#* } -> ${c1#* })"
	q=$(vm "v4l2-ctl -d $vdev --query-dv-timings" 2>&1)
	echo "$q" | grep -E 'Active width|Active height|Pixelclock|Total width|Total height|Flags' | sed 's/^/  /'
	vm "sudo dmesg" | grep 'HDMI: locked' | tail -1 | sed 's/^/  last lock line: /'
	sleep 1
	settle
}
step_modes() {
	local m r
	while read -r m r; do
		[ "$m" = 1920x1080 ] && [ "$r" = 60.00 ] && continue
		echo "== $m @ $r"
		mode_lock "mode-${m}@$r" "$m" "$r"
		live_capture "mode-${m}@$r" "$MODE_FRAMES" "$m" "$r"
	done < <(xrandr --current | awk -v o="$OUT" '$1 == o { f = 1; next }
		f && /^[^ ]/ { exit }
		f { for (i = 2; i <= NF; i++) { r = $i; gsub(/[*+]/, "", r); if (r != "") print $1, r } }')
	# 1080p60 last: from the last mode, and the way back
	echo "== 1920x1080 @ 60.00"
	mode_lock "mode-1920x1080@60.00" 1920x1080 60
	live_capture "mode-1920x1080@60.00" "$MODE_FRAMES" 1920x1080 60
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
	# the restart starts at the lock: every interval within 10 % of the
	# input's (hdmi-chips.md "Lock policy", delivery settle)
	if grep -q -- -r <<< "$opts"; then
		local cl fps
		cl=$(grep '^RESULT capture ' <<< "$out" | tail -1)
		fps=$(grep '^LOCK ' <<< "$out" | tail -1 | sed -nE 's/.* fps=([0-9.]+) .*/\1/p')
		check "$tag-restart-intervals" "$(awk -v fps="${fps:-0}" -v l="$cl" 'BEGIN {
			n = split(l, f, " "); for (i = 1; i <= n; i++) { split(f[i], kv, "="); v[kv[1]] = kv[2] }
			want = fps ? 1000 / fps : 0
			exit !(want && v["min"] >= want * 0.9 && v["max"] <= want * 1.1) }'; echo $?)" \
			"(the restart at the lock: intervals $(grep -oE 'min=[0-9.]+ max=[0-9.]+' <<< "$cl") ms, the input's $(awk -v f="${fps:-0}" 'BEGIN { if (f) printf "%.3f", 1000 / f; else print "?" }') ms, within 10 %)"
	fi
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

# The output to MODE1 RATE1 and, as soon as the driver has locked there,
# back to MODE2 RATE2: a lock in other timings for as long as the GPU takes
# to set the mode again (138 ms at 23:11:06Z in the first host soak,
# tests/logs/20261125-215755_6.8.0-151-generic_live.log). No test player
# runs: xrandr sets the mode. $5: file for the driver's lock line
blip() {
	local i t0 line=""
	"$ROOT/tools/testsrc/avsync.sh" --off
	"$ROOT/tools/testsrc/show.sh" --off
	ev "output $OUT $1@$2 (blip)"
	xrandr --output "$OUT" --mode "$1" --rate "$2"
	t0=$(date +%s%N)
	for i in $(seq 200); do
		line=$(hdmi_dbg | grep -E "^timings: ${1}p") && break
		sleep 0.02
	done
	ev "output $OUT $3@$4 (blip back $(( ($(date +%s%N) - t0) / 1000000 )) ms after the mode set; ${line:-no lock at $1})"
	xrandr --output "$OUT" --mode "$3" --rate "$4"
	echo "$line" > "$5"
}

# the video stream's counters: restarts, stops and holds (debugfs)
vid_counters() {
	vm "sudo cat $dbgdir/video" | grep -oE 'input_restarts [0-9]+ input_stops [0-9]+( input_holds [0-9]+)?'
}

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

step_blip() {
	local c0 c1 lock line ev_ms err_ms
	src_on 1920x1080 60
	time_to_lock 10 >/dev/null
	c0=$(vid_counters)
	change_while_streaming blip-continue continue "" blip 1280x720 60 1920x1080 60 /tmp/gc573-live-blip.txt
	c1=$(vid_counters)
	lock=$(cat /tmp/gc573-live-blip.txt)
	check blip-other-lock "$([ -n "$lock" ]; echo $?)" \
		"(the driver locked at 1280x720 before the mode went back: ${lock:-no})"
	check blip-held "$(awk -v a="$c0" -v b="$c1" 'BEGIN { split(a, x); split(b, y)
		exit !(y[6] != "" && y[6] >= x[6] + 1 && y[4] == x[4]) }'; echo $?)" \
		"(a hold and no stop: before $c0; after $c1)"
	# a change that stays: the stream fails once the hold has ended
	src_on 1920x1080 60
	time_to_lock 10 >/dev/null
	change_while_streaming blip-stays error "" src_on 1280x720 60
	line=$(sed -n 's/^RESULT change //p' /tmp/gc573-live-x.txt)
	ev_ms=$(grep -oE 'last_event_ms=-?[0-9]+' <<< "$line" | cut -d= -f2)
	err_ms=$(grep -oE 'dqbuf_error_ms=-?[0-9]+' <<< "$line" | cut -d= -f2)
	check blip-hold-ms "$([ "${err_ms:--1}" -ge 0 ] && [ $((err_ms - ev_ms)) -ge 900 ] &&
		[ $((err_ms - ev_ms)) -le 1600 ]; echo $?)" \
		"(DQBUF error $((${err_ms:--1} - ${ev_ms:-0})) ms after the last SOURCE_CHANGE, the lock at 720p; hold 0.9-1.6 s)"
	src_on 1920x1080 60
	time_to_lock 10 >/dev/null
}

# The colorimetry v4l2-ctl prints for a format (colorspace/transfer/
# encoding/quantization), from stdin
col_fields() {
	sed -nE 's/^\s*(Colorspace|Transfer Function|YCbCr\/HSV Encoding|Quantization)\s*:\s*(.*)$/\2/p' |
		paste -sd/
}
# TRY_FMT's colorimetry for every format, a line each ("FOURCC fields"),
# and G_FMT's for the format set now ("G_FMT:FOURCC fields"). A format not
# offered at the size (YV12 at 720 wide) is "FOURCC -": v4l2-ctl takes
# only a format ENUM_FMT lists
fmt_cols() {
	local f o c
	for f in YUYV UYVY NV12 YV12 BGR3 XR24; do
		c=$(vm "v4l2-ctl -d $vdev --try-fmt-video pixelformat=$f" 2>/dev/null | col_fields)
		echo "$f ${c:--}"
	done
	o=$(vm "v4l2-ctl -d $vdev --get-fmt-video" 2>/dev/null)
	echo "G_FMT:$(sed -nE "s/^\s*Pixel Format\s*:\s*'([^']*)'.*/\1/p" <<< "$o") $(col_fields <<< "$o")"
}
# fmt_cols' lines for the RGB formats, and for the others; the formats not
# offered left out
cols_rgb() { grep -E '^(G_FMT:)?(BGR3|XR24) ' <<< "$1" | grep -v ' -$'; }
cols_yuv() { grep -vE '^(G_FMT:)?(BGR3|XR24) ' <<< "$1" | grep -v ' -$'; }
# $1 has lines, and every one (but a format not offered) matches the
# extended regex $2
cols_all() {
	local l
	l=$(grep -v ' -$' <<< "$1")
	[ -n "$l" ] && ! grep -vqE -- "$2" <<< "$l"
}
# the formats whose colorimetry differs from $1's, with the new value
cols_diff() {
	diff <(echo "$1") <(echo "$2") | sed -n 's/^> //p' | paste -sd';' | sed 's/;/; /g'
}
# the output off, and once unlocked G_FMT on a second handle into
# $COL_FILE (a stream runs meanwhile: change_while_streaming)
COL_FILE=/tmp/gc573-live-gfmt.txt
src_off_gfmt() {
	src_off
	wait_unlocked
	vm "v4l2-ctl -d $vdev --get-fmt-video" 2>/dev/null | col_fields > "$COL_FILE"
}

step_loss() {
	local q out cols c g
	src_on 1920x1080 60
	time_to_lock 10 >/dev/null
	# the colorimetry follows the last input that locked, through a loss
	# (spec/hdmi-chips.md "Stream policy on input changes"): what TRY_FMT and
	# G_FMT give while unlocked is what they gave while locked
	cols=$(fmt_cols)
	echo "$cols" | sed 's/^/  colorimetry locked: /'
	event_during loss-idle-event src_off
	q=$(query)
	echo "  query while off: $q" | head -3
	check loss-idle-query "$(grep -qiE 'link|lock' <<< "$q"; echo $?)" "($(echo "$q" | head -1))"
	c=$(fmt_cols)
	check loss-idle-colorimetry "$([ "$c" = "$cols" ]; echo $?)" \
		"(TRY_FMT and G_FMT while unlocked: $([ "$c" = "$cols" ] && echo 'as while locked' || echo "changed: $(cols_diff "$cols" "$c")"))"
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
	c=$(fmt_cols)
	check loss-relock-colorimetry "$([ "$c" = "$cols" ]; echo $?)" \
		"(TRY_FMT and G_FMT after the relock: $([ "$c" = "$cols" ] && echo 'as before' || echo "changed: $(cols_diff "$cols" "$c")"))"
	# live stream, then the output goes off: an event, and the stream
	# carries on free-running, black (spec/video-dma.md), its format as it
	# was: G_FMT on a second handle while it runs unlocked
	rm -f "$COL_FILE"
	change_while_streaming loss-streaming continue "-o $W/lost" src_off_gfmt
	q=$(frame_black $W/lost.YUYV)
	check loss-streaming-black "$([ "$q" = 100.00 ]; echo $?)" "(last frame: $q % limited-range black)"
	g=$(cat "$COL_FILE" 2>/dev/null)
	c=$(sed -n 's/^YUYV //p' <<< "$cols")
	check loss-streaming-colorimetry "$([ -n "$g" ] && [ "$g" = "$c" ]; echo $?)" \
		"(G_FMT while the YUYV stream ran unlocked: ${g:-none}; while locked: $c)"
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

# ---- colour changes on the output (colour, colorimetry, avchange) ----
# Only on the output, at runtime (nvidia-settings --no-write-config). The
# output goes back to RGB full range (0/0) on every exit path: at the end
# of each step and in the EXIT trap (a failed or stopped run too: bash runs
# it at once at the guard's SIGTERM), read back and retried; the run stops
# if that does not take. The steps run in the pipeline's subshell, the
# trap in the script itself: a file marks a change not yet put back ($$
# is the script's PID in both).
COLOUR_MARK=/tmp/gc573-live-colour-$$
COLOUR_ATTRS="ColorSpace ColorRange CurrentColorSpace CurrentColorRange Dithering CurrentDithering"
# every connected output's colour settings, read-only, as
# "OUTPUT space/range/current space/current range/dithering/current; "
colour_query() {
	local o a
	local -a q
	for o in $(xrandr --query | awk '/ connected/ { print $1 }'); do
		q=()
		for a in $COLOUR_ATTRS; do q+=(-q "[DPY:$o]/$a"); done
		printf '%s %s; ' "$o" "$(nvidia-settings -t "${q[@]}" 2>/dev/null | paste -sd/)"
	done
}
colour_set() {	# ColorSpace ColorRange, on the output only, never the primary
	local primary
	primary=$(xrandr --query | awk '/ connected primary/ { print $1; exit }')
	if [ -z "$primary" ] || [ "$primary" = "$OUT" ]; then
		echo "live.sh: no colour change: $OUT is the primary output, or there is none" >&2
		return 1
	fi
	touch "$COLOUR_MARK"
	ev "colour ColorSpace=$1 ColorRange=$2"
	nvidia-settings --no-write-config -a "[DPY:$OUT]/ColorSpace=$1" -a "[DPY:$OUT]/ColorRange=$2" > /dev/null 2>&1
}
# the output back to RGB full range (0/0), read back; three tries
colour_restore() {
	local i q
	[ -e "$COLOUR_MARK" ] || return 0
	for i in 1 2 3; do
		nvidia-settings --no-write-config -a "[DPY:$OUT]/ColorSpace=0" -a "[DPY:$OUT]/ColorRange=0" > /dev/null 2>&1
		q=$(nvidia-settings -t -q "[DPY:$OUT]/ColorSpace" -q "[DPY:$OUT]/ColorRange" 2>/dev/null | paste -sd/)
		ev "colour ColorSpace=0 ColorRange=0 (put back, try $i: reads $q)"
		[ "$q" = 0/0 ] && { rm -f "$COLOUR_MARK"; return 0; }
		sleep 1
	done
	ev "COLOUR NOT PUT BACK: $OUT reads ColorSpace/ColorRange $q"
	echo "COLOUR NOT PUT BACK: $OUT reads ColorSpace/ColorRange $q, not 0/0" >&2
	return 1
}
# the output's colour could not be put back: stop the run ($1: tag)
colour_stop() {
	result "$1" FAIL "($OUT's colour is not back at RGB full range: the run stops; the EXIT trap tries again)"
	echo "SUMMARY stopped: $OUT's colour could not be put back"
	exit 3
}
# $2 (colour_query after) against $1 (before): every other output as it
# was; the output at RGB full range, set and sent, dithering off as show.sh
# leaves it
colour_settings_ok() {
	[ "$(sed 's/; /\n/g' <<< "$1" | grep -v "^$OUT ")" = "$(sed 's/; /\n/g' <<< "$2" | grep -v "^$OUT ")" ] &&
		sed 's/; /\n/g' <<< "$2" | grep -qx "$OUT 0/0/0/0/2/0"
}

step_colour() {
	local cs cr name
	src_mode 1920x1080 60
	for cs_cr in "0 1 rgb-limited" "2 1 ycbcr444" "1 1 ycbcr422"; do
		set -- $cs_cr
		cs=$1 cr=$2 name=$3
		colour_set "$cs" "$cr"
		sleep 2
		settle
		hdmi_dbg | grep -E '^(it6805: mode|splitter: avi|input:)' | sed 's/^/  /'
		avi_check "colour-$name"
		live_capture "colour-$name" 60 1920x1080 60
		result "colour-$name-note" SKIP "(report only, not gating)"
	done
	colour_restore || colour_stop colour-restore
	sleep 3
}

# ---- colorimetry: the format follows the last input that locked ----
# (spec/hdmi-chips.md "Stream policy on input changes"). The colour
# settings of every output are queried, read-only, before and after: the
# others must not change.
# fmt_cols once it differs from $1 (a colour change, taken at its lock: up
# to about 14 s), the source settled again
cols_change() {
	local i
	for i in $(seq 16); do
		[ "$(fmt_cols)" != "$1" ] && break
		sleep 0.5
	done
	settle
	fmt_cols
}
# what the source sends now (the GPU's current colour space and range)
colour_sent() {
	nvidia-settings -t -q "[DPY:$OUT]/CurrentColorSpace" -q "[DPY:$OUT]/CurrentColorRange" 2>/dev/null | paste -sd/
}
step_colorimetry() {
	local q0 q1 a b c d r e f g y
	q0=$(colour_query)
	echo "  colour settings before: $q0"
	# RGB full range, 1080p60: sRGB, the YUV outputs limited range in
	# BT.709, the RGB outputs full range
	src_mode 1920x1080 60
	a=$(fmt_cols)
	echo "$a" | sed "s|^|  RGB full range (sent $(colour_sent)): |"
	check colorimetry-rgb-full "$(cols_all "$a" ' sRGB/sRGB/Rec\. 709/' && cols_all "$(cols_rgb "$a")" '/Full Range$' &&
		cols_all "$(cols_yuv "$a")" '/Limited Range$'; echo $?)" \
		"(YUYV $(sed -n 's/^YUYV //p' <<< "$a"); XR24 $(sed -n 's/^XR24 //p' <<< "$a"))"
	# YCbCr 4:4:4 limited range (BT.709 at 1080p), as a console or a
	# streaming box sends after the PC's RGB: every format in BT.709 at its
	# lock, the RGB outputs full range (converted)
	colour_set 2 1
	b=$(cols_change "$a")
	echo "$b" | sed "s|^|  YCbCr 4:4:4 limited range (sent $(colour_sent)): |"
	check colorimetry-ycbcr444 "$(cols_all "$b" ' Rec\. 709/Rec\. 709/Rec\. 709/' && cols_all "$(cols_rgb "$b")" '/Full Range$' &&
		cols_all "$(cols_yuv "$b")" '/Limited Range$'; echo $?)" \
		"(at the lock: YUYV $(sed -n 's/^YUYV //p' <<< "$b"); XR24 $(sed -n 's/^XR24 //p' <<< "$b"))"
	# RGB limited range: sRGB again at its lock, and the RGB outputs keep
	# the input's range (no conversion)
	colour_set 0 1
	c=$(cols_change "$b")
	echo "$c" | sed "s|^|  RGB limited range (sent $(colour_sent)): |"
	check colorimetry-rgb-limited "$(cols_all "$c" ' sRGB/sRGB/Rec\. 709/Limited Range$'; echo $?)" \
		"(at the lock: XR24 $(sed -n 's/^XR24 //p' <<< "$c"); YUYV $(sed -n 's/^YUYV //p' <<< "$c"))"
	# a loss in RGB limited range: every format as it was (the M2 setup
	# would be BT.709 and full-range RGB)
	src_off
	wait_unlocked
	d=$(fmt_cols)
	check colorimetry-loss "$([ "$d" = "$c" ]; echo $?)" \
		"(TRY_FMT and G_FMT while unlocked: $([ "$d" = "$c" ] && echo 'as in RGB limited range' || echo "changed: $(cols_diff "$c" "$d")"))"
	# the relock, still RGB limited range
	src_mode 1920x1080 60
	r=$(fmt_cols)
	check colorimetry-relock "$([ "$r" = "$c" ]; echo $?)" \
		"(sent $(colour_sent); after the relock: $([ "$r" = "$c" ] && echo 'as in RGB limited range' || echo "changed: $(cols_diff "$c" "$r")"))"
	# RGB full range again: as at the start
	colour_restore || colour_stop colorimetry-restore
	e=$(cols_change "$c")
	check colorimetry-rgb-full-again "$([ "$e" = "$a" ]; echo $?)" \
		"(sent $(colour_sent): $([ "$e" = "$a" ] && echo 'as at the start' || echo "differs: $(cols_diff "$a" "$e")"))"
	# 720x480 RGB full range: the YUV outputs in BT.601 (by size); a loss
	# while a YUYV stream runs keeps it (G_FMT on a second handle), and the
	# free-run black is black through the RGB->YUV CSC in BT.601
	src_mode 720x480 59.94
	f=$(fmt_cols)
	echo "$f" | sed 's|^|  720x480 RGB full range: |'
	y=$(sed -n 's/^YUYV //p' <<< "$f")
	check colorimetry-601 "$(cols_all "$(cols_yuv "$f")" ' sRGB/sRGB/ITU-R 601/Limited Range$'; echo $?)" "(YUYV $y)"
	rm -f "$COL_FILE"
	change_while_streaming colorimetry-601-loss continue "-o $W/lost601" src_off_gfmt
	g=$(cat "$COL_FILE" 2>/dev/null)
	check colorimetry-601-gfmt "$([ -n "$g" ] && [ "$g" = "$y" ]; echo $?)" \
		"(G_FMT while the YUYV stream ran unlocked: ${g:-none}; while locked: $y)"
	q1=$(frame_black $W/lost601.YUYV)
	check colorimetry-601-black "$([ "$q1" = 100.00 ]; echo $?)" "(last frame: $q1 % limited-range black)"
	src_mode 1920x1080 60
	q1=$(colour_query)
	echo "  colour settings after: $q1"
	check colorimetry-settings "$(colour_settings_ok "$q0" "$q1"; echo $?)" \
		"(before: $q0 after: $q1: the other outputs as they were, $OUT at RGB full range, dithering off)"
}

# M4: avsync.sh's bursts on the HDMI audio, 10 s
step_audio() {
	local out
	av_on || { result audio-source FAIL "(avsync.sh or the IT6805 audio state ON)"; av_off; return; }
	hdmi_dbg | grep -E '^it6805: (state|audio)' | sed 's/^/  /'
	aud "-t 10 -v -o $W/audio.raw" > /tmp/gc573-live-a.txt 2>&1
	check audio-capture $? "($(grep -E '^RESULT' /tmp/gc573-live-a.txt))"
	put /tmp/gc573-live-a.txt "$W/audio.txt"
	out=$(vm "python3 $W/live-av.py $W/audio.txt $W/audio.raw --bursts")
	av_results audio "$out"
	aud_dbg | sed 's/^/  /'
	av_off
}

# The test source on the card, frame by frame: every source frame captured
# once. The counter picture (counter-graph.sh) through the driver: show.sh
# --counter (ffplay paced by the system clock) and avsync.sh --pattern
# (paced by the HDMI audio clock, which runs with the GPU's pixel clock).
# One RESULT per source and mode; the INFO lines say what the capture saw
step_exact() {
	local spec kind mode rate name out i d ex src
	for spec in "counter 1920x1080 60" "pattern 1920x1080 60" "pattern 1920x1080 59.94" \
		"pattern 1280x720 59.94"; do
		read -r kind mode rate <<< "$spec"
		name=exact-$kind-${mode#*x}p$rate
		wait_connected 15
		if [ "$kind" = counter ]; then
			"$ROOT/tools/testsrc/show.sh" --counter "$OUT" "$mode" "$rate" > /dev/null ||
				{ result "$name" FAIL "(show.sh --counter)"; continue; }
		else
			# the mode first: avsync.sh needs the HDMI audio port's ELD
			src_on "$mode" "$rate"
			for i in $(seq 30); do
				"$ROOT/tools/testsrc/avsync.sh" --pattern "$OUT" "$mode" "$rate" > /dev/null 2>&1 && break
				sleep 0.5
			done
			[ "$i" -lt 30 ] || { result "$name" FAIL "(avsync.sh --pattern)"; continue; }
			for i in $(seq 40); do
				d=$(aud_dbg)
				grep -q 'it6805 audio on' <<< "$d" && grep -q '(48000 Hz)' <<< "$d" && break
				sleep 0.25
			done
		fi
		sleep 3
		vm "sudo $W/gc573-aud -D $pcm -t $EXACT_SECS -v -V $vdev -P -o $W/exact.raw > $W/exact.txt 2>&1"
		out=$(vm "python3 $W/live-av.py $W/exact.txt $W/exact.raw --exact $kind $rate")
		vm "rm -f $W/exact.raw"
		# (show.sh --counter plays no audio: live-av.py's audio lines do not apply)
		grep -E "^INFO|^RESULT +(video|exact)$([ "$kind" = counter ] || echo '|raw offsets|^RESULT +avsync')" <<< "$out" |
			sed 's/^/  /'
		ex=$(sed -n 's/^RESULT exact *\(PASS\|FAIL\) (\(.*\))$/\1 \2/p' <<< "$out")
		src=$(sed -n 's/^INFO source *\([0-9]* frames shown twice, [0-9]* skipped, [0-9]* torn\).*; net \([-+0-9]*\) frames .*the clocks predict \([-+0-9.]*\) .*; \([^;]*\)$/\1, net \2 (the clocks: \3): \4/p' <<< "$out")
		check "$name" "$([ "${ex%% *}" = PASS ]; echo $?)" \
			"($EXACT_SECS s: ${ex#* }; the source: ${src:-no counters read})"
	done
	"$ROOT/tools/testsrc/avsync.sh" --off
	src_on 1920x1080 60
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
# ALSA PCM by its control node's PCI path (find_vdev: never by the card's id)
# obs_up [FORMAT]: the recording format (tests/obs-run.sh), default hybrid_mp4
obs_up() {
	if [ "$LOCAL" = 1 ]; then
		# the user's OBS: started minimized, its sources checked, not set up
		vm "GC573_OBS_RECFORMAT=${1:-hybrid_mp4} bash $W/obs-run.sh start --keep-config" | sed 's/^/  /' &&
			obsc "verify /dev/v4l/by-path/pci-${dbgdir#*/gc573-}-video-index0 $pcm" | sed 's/^/  /'
		return
	fi
	vm "GC573_OBS_RECFORMAT=${1:-hybrid_mp4} bash $W/obs-run.sh start" | sed 's/^/  /' &&
		obsc "setup /dev/v4l/by-path/pci-${dbgdir#*/gc573-}-video-index0 $pcm" | sed 's/^/  /'
}

# OBS holds the device while it runs: each OBS step stops it at the end
obs_down() { vm "bash $W/obs-run.sh stop$([ "$LOCAL" = 0 ] || echo ' --keep-config')" > /dev/null; }

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
		put "$ROOT/tests/obspw.lua" "$PW_WP"
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
	local out p t0 k st n dmax offs rc
	av_on || { result avchange-source FAIL "(avsync.sh or the IT6805 audio state ON)"; av_off; return; }
	sleep 3
	vm "sudo $W/gc573-aud -D $pcm -t 80 -v -V $vdev -o $W/avc.raw > $W/avc.txt 2>&1" &
	p=$!
	t0=$(date +%s)
	for k in "20 2 1" "40 0 1" "60 0 0"; do
		set -- $k
		while [ $(($(date +%s) - t0)) -lt "$1" ]; do sleep 0.1; done
		colour_set "$2" "$3"
	done
	wait $p
	rc=$?
	colour_restore || colour_stop avchange-restore
	check avchange-capture $rc "($(vm "grep -E '^(PARAMS|RESULT)' $W/avc.txt" | tr '\n' ' '))"
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
	out=$(python3 "$ROOT/tests/obs-events.py" events --reps "$OBSEV_REPS" "${OBSEV_ARGS[@]}" 2>&1)
	av_results obsevents "$out"
	lg=$(obs_log_since "$m")
	echo "  obs: $(grep -c 'select timed out' <<< "$lg") select timeouts, $(grep -c 'failed to dequeue' <<< "$lg") dequeue failures, $(grep -c 'Start capture' <<< "$lg") device opens"
	# The frame-size changes again while OBS records. Hybrid MP4 (OBS was
	# started with it) is OBS's own muxer: the reopen works during the
	# recording, which must play the pattern before and after. MKV runs the
	# obs-ffmpeg-mux helper, which holds OBS's descriptor of the device: the
	# reopen cannot work until the recording stops (report only)
	out=$(python3 "$ROOT/tests/obs-events.py" events --reps 1 --only res-720p,res-1080p --record \
		"${OBSEV_ARGS[@]}" 2>&1)
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
	out=$(python3 "$ROOT/tests/obs-events.py" events --reps 1 --only res-720p,res-1080p --record \
		"${OBSEV_ARGS[@]}" 2>&1)
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
	[ "$LOCAL" = 0 ] || { obssoak_local; return; }
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
	out=$(python3 "$ROOT/tests/obs-events.py" soak "$OBSSOAK_SECS" --every "$OBSSOAK_EVERY" \
		"${OBSEV_ARGS[@]}" ${OBSSOAK_INJECT:+--inject "$OBSSOAK_INJECT"} 2>&1)
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

# ---- obssoak on the host (local mode) ----

# The driver's A/V offset in the avsync.sh --pattern session that runs, from
# its own timestamps: gc573-aud -V -P for $2 s (the flash box, and the
# counter, which shows the test source's pacing), checked as in step avsync.
# Results as RESULT $1-NAME; sets ref, the raw mean offset in ms (burst onset
# - flash frame, as obs-av.py measures it in a recording)
driver_ref() {
	local out
	vm "sudo $W/gc573-aud -D $pcm -t $2 -v -V $vdev -P -o $W/ref.raw > $W/ref.txt 2>&1"
	check "$1-capture" $? "($(vm "grep -E '^(PARAMS|RESULT)' $W/ref.txt" | tr '\n' ' '))"
	out=$(vm "python3 $W/live-av.py $W/ref.txt $W/ref.raw --min-secs $(($2 * 9 / 10))")
	vm "rm -f $W/ref.raw"
	av_results "$1" "$(grep -E '^RESULT +(duration|xruns|gaps|video|avsync)|raw offsets|^INFO' <<< "$out")"
	ref=$(sed -n 's/^  raw offsets: mean \([-+0-9.]*\) ms.*/\1/p' <<< "$out")
}

# One line a minute while the host soak runs: UTC seconds; MemAvailable,
# Slab, SUnreclaim, VmallocUsed, Percpu (kB); OBS's RSS (kB) and CPU ticks;
# the IRQ thread's CPU ticks; the machine's busy:idle CPU ticks; kernel log
# lines since the run's mark: all, the driver's, bad ones (tests/lib.sh);
# then the driver's counters from debugfs as v_ (video), a_ (audio), h_,
# it_, sp_ (HDMI poll loop, IT6805, splitter) NAME=N
host_sample() {
	local irq obs k
	irq=$(ps -eo pid,comm | awk '$2 ~ /^irq\/[0-9]+-gc573/ { print $1; exit }')
	obs=$(pgrep -x obs | head -1)
	k=$(vm "sudo dmesg" | awk -v m="gc573-live: $kmark" 'f; index($0, m) { f = 1 }')
	printf '%s %s%s %s %s %s %s %s %s | ' "$(date +%s)" \
		"$(awk '/^(MemAvailable|Slab|SUnreclaim|VmallocUsed|Percpu):/ { printf "%s ", $2 }' /proc/meminfo)" \
		"$(awk '/^VmRSS:/ { print $2 }' "/proc/${obs:-0}/status" 2>/dev/null || echo -)" \
		"$(awk '{ print $14 + $15 }' "/proc/${obs:-0}/stat" 2>/dev/null || echo -)" \
		"$(awk '{ print $14 + $15 }' "/proc/${irq:-0}/stat" 2>/dev/null || echo -)" \
		"$(awk '/^cpu / { print $2 + $3 + $4 + $6 + $7 + $8 ":" $5 }' /proc/stat)" \
		"$(grep -c . <<< "$k")" "$(grep -c gc573 <<< "$k")" \
		"$( { grep -E "$KMSG_BAD" <<< "$k"; grep -E "$KMSG_DRV_BAD" <<< "$k"; } | grep -c .)"
	{
		vm "sudo grep -E '^(stream|stats):' $dbgdir/video" | sed 's/^/v_ /'
		vm "sudo grep -E '^(periods|order) ' $dbgdir/audio" | sed 's/^/a_ /'
		vm "sudo grep -E '^hdmi:' $dbgdir/hdmi" | sed 's/^/h_ /'
		vm "sudo grep -E '^it6805: state' $dbgdir/hdmi" | sed 's/^/it_ /'
		vm "sudo grep -E '^splitter: (rx|tx1)' $dbgdir/hdmi" | sed 's/^/sp_ /'
	} | awk '{ for (i = 2; i < NF; i++) if ($i ~ /^[a-z_]+$/ && $(i + 1) ~ /^[0-9]+$/) printf "%s%s=%s ", $1, $i, $(i + 1) }'
	echo
}

# The host form of obssoak: the driver's A/V offset for 60 s in the first
# source session; OBS started minimized, its sources checked; the event soak
# (tests/obs-events.py soak, the rotation GC573_OBSSOAK_ROTATION) recording
# to GC573_REC_DIR, with the source of the first segment kept and that of
# the last one left running; a sample a minute (host_sample); OBS stopped;
# the driver's offset in the last session. Then the recording (pattern,
# counter steps, the A/V offset per segment, OBS's own part at the first
# and last segments against the driver's), memory, CPU, the driver's
# counters, OBS's log; the recording is deleted.
# SUnreclaim (kB), then each slab cache's live objects (kB)
mem_snapshot() {
	awk '/^SUnreclaim:/ { print "SUnreclaim", $2 }' /proc/meminfo
	vm "sudo cat /proc/slabinfo" | awk 'NR > 2 { printf "%s %d\n", $1, $2 * $4 / 1024 }'
}

# The driver's own video buffer memory live now, over all its cards
# (debugfs video "mem": vb2 buffers, their pages and kernel mappings, DMA
# descriptor lists): "bufs N pages N vmaps N dlists N dl_bytes N". All 0
# while no application has buffers. Empty for a module built before it
drv_mem() { vm "sudo cat $dbgdir/video" 2>/dev/null | sed -n 's/^mem (live, all cards): //p'; }
DRV_MEM_ZERO="bufs 0 pages 0 vmaps 0 dlists 0 dl_bytes 0"

# After the steps, with no stream: nothing of the driver's own buffer
# memory left (a leak check that other programs cannot move; kmemleak on
# the debug kernel covers the rest)
drv_mem_check() {
	local m
	m=$(drv_mem)
	if [ -z "$m" ]; then
		result driver-mem SKIP "(the loaded gc573 has no live-memory line in debugfs video: built before it)"
	else
		check driver-mem "$([ "$m" = "$DRV_MEM_ZERO" ]; echo $?)" "(live after the steps: $m)"
	fi
}

obssoak_local() {
	local out f m lg sm marks refa="" refc="" seg sp avail first last mem0 mem1 top drv0 drv1
	lib_kmsg_patterns	# for host_sample
	mkdir -p "$REC_DIR" || { result obssoak-recdir FAIL "(cannot make $REC_DIR)"; return; }
	# OBS's Simple output: about 6.2 Mb/s; room for three times that
	avail=$(df -k --output=avail "$REC_DIR" | tail -1)
	[ "$avail" -gt $((OBSSOAK_SECS * 6200 / 8 * 3)) ] ||
		{ result obssoak-recdir FAIL "($REC_DIR: $((avail / 1024)) MB free)"; return; }
	echo "  recording to $REC_DIR ($((avail / 1048576)) GB free); rotation $OBSSOAK_ROTATION"
	# the Roku's pattern video plays already (rokuobssoak)
	[ "$SOURCE" = roku ] || av_on --pattern ||
		{ result obssoak-source FAIL "(avsync.sh --pattern or the IT6805 audio state ON)"; av_off; return; }
	sleep 3
	driver_ref obssoak-driver-first 60
	refa=$ref
	# memory before OBS: the leak check compares it with after OBS and the
	# recording are gone (the recording's page cache grows SUnreclaim on
	# any file system: tests/logs/20261126T0017Z-host-slab-attribution.log)
	mem0=$(mem_snapshot)
	drv0=$(drv_mem)
	obs_up || { result obssoak-start FAIL "(OBS minimized, with the sources expected)"; obs_down; av_off; return; }
	m=$(obs_log_mark)
	sp=${log%.log}-obssoak-samples.txt
	( while :; do host_sample; sleep 60; done ) > "$sp" 2>&1 &
	local sampler=$!
	echo "  obssoak: $OBSSOAK_SECS s from $(date -u '+%H:%M:%S UTC'), a change every $OBSSOAK_EVERY s"
	out=$(python3 "$ROOT/tests/obs-events.py" soak "$OBSSOAK_SECS" --every "$OBSSOAK_EVERY" \
		--rotation "$OBSSOAK_ROTATION" --keep-source --no-restore --rec-dir "$REC_DIR" \
		"${OBSEV_ARGS[@]}" ${OBSSOAK_INJECT:+--inject "$OBSSOAK_INJECT"} 2>&1)
	host_sample >> "$sp" 2>&1
	kill "$sampler" 2>/dev/null
	wait "$sampler" 2>/dev/null
	av_results obssoak "$(grep -v '^SHOT ' <<< "$out")"
	echo "  screenshots that were not good: $(grep -c '^SHOT ' <<< "$out") (SHOT lines in the event log's run)"
	grep '^SHOT ' <<< "$out" > "${log%.log}-obssoak-shots.txt"
	obs_down
	# OBS's log of this run, complete now that OBS has stopped
	lg=$(vm "tail -n +$((m + 1)) \"\$(ls -t ~/.config/obs-studio/logs/*.txt | head -1)\"")
	sleep 2
	# the last segment's source session runs on: the driver's offset in it
	driver_ref obssoak-driver-last 60
	refc=$ref
	f=$(sed -n 's/^RECORDING //p' <<< "$out")
	marks=$(sed -n 's/^MARK //p' <<< "$out" | paste -sd,)
	if [ -n "$f" ] && [ -f "$f" ]; then
		echo "  recording: $(du -h "$f" | cut -f1) $f"
		av_results obssoak "$(python3 "$ROOT/tests/obs-events.py" recheck "$f" --every 30 --across 2>&1)"
		seg=$(python3 "$ROOT/tests/obs-av.py" "$f" --box 0.70,0.88,0.92,0.92 ${marks:+--segments $marks} 2>&1)
		av_results obssoak-rec "$seg"
		# OBS's own part of the offset where the driver's is known: the
		# first and the last segment, each in the session gc573-aud measured.
		# It grows: libobs lays the card's samples back to back while their
		# timestamps stay within 70 ms of where it expects them, and the
		# HDMI audio clock runs about 25 ppm against the host's; at 70 ms
		# libobs puts the audio back at its timestamps (audio-timeline above
		# finds those resets). So it is bounded, not constant: from a frame
		# period early to 70 ms plus a frame period late (the 2-hour soak:
		# -0.2 and +45.3 ms, tests/logs/20261126-004854_6.8.0-151-generic_live.log)
		first=$(sed -n 's/^SEGMENT 0 .* offset=\([-+0-9.]*\) .*/\1/p' <<< "$seg")
		last=$(grep '^SEGMENT ' <<< "$seg" | tail -1 | sed -n 's/.* offset=\([-+0-9.]*\) .*/\1/p')
		if [ -n "$first" ] && [ -n "$last" ] && [ -n "$refa" ] && [ -n "$refc" ]; then
			out=$(awk -v f="$first" -v a="$refa" -v l="$last" -v c="$refc" 'BEGIN {
				d1 = f - a; d2 = l - c
				ok = d1 >= -16.7 && d1 <= 86.7 && d2 >= -16.7 && d2 <= 86.7
				printf "RESULT obs-own %s (OBS - driver in the same source session: first segment %+.1f ms (OBS %+.1f, driver %+.2f), last %+.1f ms (OBS %+.1f, driver %+.2f); both within OBS'"'"'s bound, a frame period early to its 70 ms timestamp smoothing plus a frame period late, -16.7 to +86.7 ms)\n",
					ok ? "PASS" : "FAIL", d1, f, a, d2, l, c }')
			av_results obssoak "$out"
		else
			result obssoak-obs-own FAIL "(offsets missing: first segment ${first:--}, last ${last:--}, driver ${refa:--} and ${refc:--})"
		fi
		rm -f "$f"
	else
		result obssoak-recording FAIL "(no recording: ${f:-none})"
	fi
	rmdir "$REC_DIR" 2>/dev/null
	sync
	sleep 10
	mem1=$(mem_snapshot)
	drv1=$(drv_mem)
	top=$(join <(sort <<< "$mem0") <(sort <<< "$mem1") |
		awk '$1 != "SUnreclaim" { d = $3 - $2; if (d >= 128 || d <= -128) printf "%s %+d\n", $1, d }' |
		sort -k2 -n -r | head -8 | paste -sd, | sed 's/,/, /g')
	# the kmalloc caches' live objects, from before OBS to after it, for
	# context: every program's (the 2-hour soak's +1798 kB could not be
	# told apart: tests/logs/20261126-004854_6.8.0-151-generic_live.log)
	out=$(join <(sort <<< "$mem0") <(sort <<< "$mem1") | awk -v top="$top" '
		$1 == "SUnreclaim" { a = $2; b = $3; next }
		$1 ~ /^kmalloc-([0-9]+k?|rnd-[0-9]+-[0-9]+k?)$/ { k0 += $2; k1 += $3 }
		END {
			printf "INFO memory-kmalloc live objects in the kmalloc caches: %d kB before OBS started, %d kB after OBS exited and the recording was deleted, %+d kB (every program: the random kmalloc caches cannot be told apart); SUnreclaim %d -> %d kB (%+d); slab caches that moved by 128 kB or more (kB): %s\n",
				k0, k1, k1 - k0, a, b, b - a, top == "" ? "none" : top }')
	av_results obssoak "$out"
	# the leak check: the driver's own buffer memory (debugfs video
	# "mem"), all of it given back once OBS has gone
	if [ -z "$drv0" ] || [ -z "$drv1" ]; then
		result obssoak-memory SKIP "(the loaded gc573 has no live-memory line in debugfs video: built before it; the kmalloc caches above are INFO only)"
	else
		check obssoak-memory "$([ "$drv1" = "$DRV_MEM_ZERO" ] && [ "$drv0" = "$DRV_MEM_ZERO" ]; echo $?)" \
			"(the driver's own buffer memory, debugfs video \"mem\": before OBS $drv0; after OBS exited $drv1)"
	fi
	# memory, CPU and the driver's counters over the soak (host_sample)
	sm=$(cat "$sp")
	awk 'NR == 1 || NR % 10 == 0 { print "  mem: " $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13 }' <<< "$sm"
	out=$(awk -v hz="$(getconf CLK_TCK)" '
		$14 == "|" { n++; t[n] = $1; avail[n] = $2; slab[n] = $3; sunr[n] = $4; vm[n] = $5; rss[n] = $7
			obs[n] = $8; irq[n] = $9; split($10, c, ":"); busy[n] = c[1]; idle[n] = c[2] }
		END {
			if (n < 7) { print "INFO memory while recording: " n " samples, fewer than 7"; exit }
			s = 6
			du = sunr[n] - sunr[s]
			printf "INFO memory while recording, from minute 5 to the end: SUnreclaim %+d kB (the page cache of the recording counts: memcg vectors, about 600 x 512 bytes per 100 MiB written), Slab %+d kB, VmallocUsed %+d kB, MemAvailable %+d kB, OBS RSS %+d kB\n",
				du, slab[n] - slab[s], vm[n] - vm[s], avail[n] - avail[s], rss[n] - rss[s]
			wall = t[n] - t[1]
			printf "RESULT cpu PASS (report only: OBS %.1f %% of one CPU, the IRQ thread %.2f %%, the host %.1f %% of its CPUs, over %d s)\n",
				(obs[n] - obs[1]) / hz / wall * 100, (irq[n] - irq[1]) / hz / wall * 100,
				(busy[n] - busy[1]) / ((busy[n] - busy[1]) + (idle[n] - idle[1])) * 100, wall
		}' <<< "$sm")
	av_results obssoak "$out"
	out=$(awk '
		$14 == "|" { n++; for (i = 15; i <= NF; i++) { split($i, kv, "="); v[n, kv[1]] = kv[2]; names[kv[1]] = 1 }
			kall[n] = $11; kdrv[n] = $12; kbad[n] = $13 }
		END {
			split("v_bad_status v_unarmed v_order a_bad_done a_order h_poll_errors h_xfer_errors", errs, " ")
			for (i in errs) iserr[errs[i]] = 1
			for (k in names) {
				d = v[n, k] - v[1, k]
				if (k ~ /^(v_(skipped|multi|stale|terms|term_missing|underruns|input_restarts|input_stops|input_holds|bad_status|unarmed|order)|a_(silent|pauses|starts|restarts|stops|stop_missing|stale|late|bad_done|order)|h_(failed|poll_errors|xfer_errors|retries|resyncs|runs|fpga_rejects)|it_(entries|losses|releases)|sp_(link_errors|level_changes|repowers|failed|pll_recoveries|scdc_aborts))$/ && d)
					info = info sprintf(" %s %+d", k, d)
				if (k in iserr && d) bad = bad sprintf(" %s %+d", k, d)
			}
			printf "RESULT driver-counters %s (over the soak, %d samples:%s%s; kernel log: %d lines, %d of the driver, %d bad)\n",
				bad == "" ? "PASS" : "FAIL", n, info == "" ? " no event counter moved" : info,
				bad == "" ? "" : "; errors:" bad, kall[n], kdrv[n], kbad[n]
		}' <<< "$sm")
	av_results obssoak "$out"
	echo "  obs: $(grep -c 'select timed out' <<< "$lg") select timeouts, $(grep -c 'failed to dequeue' <<< "$lg") dequeue failures, $(grep -c 'Start capture' <<< "$lg") device opens"
	grep -E 'skipped frames|lagged frames|Total (frames output|drawn frames)|Recording (Start|Stop)' <<< "$lg" |
		sed 's/^/  obs log: /' | head -12
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
	lib_kmsg_patterns
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

# ---- apps: ffmpeg, GStreamer and VLC on the card (app neutrality) ----
# The driver favours no application: each one present is checked headless,
# into a file (no display sink, no audio playback), on the GC573's nodes
# named explicitly (nothing that lists or probes other devices):
# - captures of avsync.sh --pattern with the card's audio, GC573_APPS_SECS
#   (10) s each: 1080p60 and 720p59.94 YUYV, and 1080p60 NV12, checked by
#   tests/app-check.py (frames against the counter, the pattern, channel
#   order, rate, the A/V offset where the file keeps timestamps, against
#   the driver's own in the same source session: gc573-aud first);
# - one of each source change while it records 30 s, 8 s in: sleep/wake
#   (output off 5 s), a same-mode relock (EDID re-set with a hot-plug),
#   60 -> 59.94 Hz, 1080p60 -> 720p59.94. What it did (an APP line: it
#   subscribed to events and dequeued them or not, from strace, which does
#   not decode the event type; the driver raises V4L2_EVENT_SOURCE_CHANGE
#   at every change; carried on, errored out or froze; app-check.py
#   --change), and whether a restart at the new mode brings it back (a 6 s
#   capture, live frames).
# GStreamer's v4l2 plugin opens every /dev/video* node whenever it loads
# (its M2M probe, "Probing devices"), cameras too: on the host (local mode)
# it is skipped; GST_REGISTRY_UPDATE=no keeps registry rebuilds out too.
# The files go to GC573_APPS_DIR (default /var/tmp/gc573-apps), deleted
# after each check.
APPS_DIR=${GC573_APPS_DIR:-/var/tmp/gc573-apps}
APPS_SECS=${GC573_APPS_SECS:-10}
APPS=${GC573_APPS:-ffmpeg gst vlc}

app_missing() {	# app: empty if it can run here, else why not
	case $1 in
	ffmpeg)
		vm "command -v ffmpeg >/dev/null" || { echo "no ffmpeg"; return; }
		vm "ffmpeg -hide_banner -devices 2>/dev/null | grep -qE '[ ,]v4l2 ' &&
			ffmpeg -hide_banner -devices 2>/dev/null | grep -q ' alsa ' &&
			ffmpeg -hide_banner -encoders 2>/dev/null | grep -q ' libx264 '" ||
			echo "ffmpeg without v4l2, alsa or libx264" ;;
	gst)
		[ "$LOCAL" = 0 ] || { echo "not on this host: GStreamer's v4l2 plugin opens every /dev/video* node when it loads (cameras too)"; return; }
		vm "command -v gst-launch-1.0 >/dev/null" || { echo "no gst-launch-1.0"; return; }
		vm "for e in v4l2src alsasrc matroskamux videoconvert; do GST_REGISTRY_UPDATE=no gst-inspect-1.0 --exists \$e || exit 1; done" ||
			echo "GStreamer without v4l2src, alsasrc, matroskamux or videoconvert" ;;
	vlc)
		# by its plugin files: VLC's own listings (--list, -H, -p) load
		# every module, and some list devices (AGENTS.md: never on the
		# host). Matroska goes through libavformat (VLC 3 has no muxer of
		# its own: std{mux=mkv} falls back to avformat{mux=matroska})
		vm "command -v cvlc >/dev/null" || { echo "no cvlc"; return; }
		vm "p=\$(dirname \$(ls -d /usr/lib*/vlc/plugins/access /usr/lib*/*/vlc/plugins/access 2>/dev/null | head -1)) &&
			[ -f \$p/access/libv4l2_plugin.so ] && [ -f \$p/access/libaccess_alsa_plugin.so ] &&
			[ -f \$p/codec/libx264_plugin.so ] && [ -f \$p/demux/libavformat_plugin.so ]" ||
			echo "VLC without its v4l2, ALSA, x264 or avformat plugin" ;;
	esac
}
app_version() {
	case $1 in
	ffmpeg) vm "ffmpeg -version | awk 'NR == 1 { print \$3 }'" ;;
	gst) vm "gst-launch-1.0 --version | sed -n 's/^GStreamer \\([0-9.]*\\).*/\\1/p' | head -1" ;;
	vlc) vm "dpkg-query -W -f '\${Version}' vlc-bin 2>/dev/null || rpm -q --qf '%{VERSION}' vlc 2>/dev/null" ;;
	esac
}
# The command that records SECS s of MODE at RATE in FMT (yuyv, nv12) with
# the card's audio into FILE; WRAP (e.g. strace) goes in front
app_cmd() {	# app fmt mode rate secs file [wrap]
	local app=$1 fmt=$2 mode=$3 rate=$4 secs=$5 f=$6 wrap=${7:-} fr w h
	fr=$rate; [ "$rate" = 59.94 ] && fr=60000/1001
	w=${mode%x*} h=${mode#*x}
	case $app in
	ffmpeg)
		echo "$wrap ffmpeg -nostdin -hide_banner -loglevel error -f v4l2 -ts mono2abs" \
			"-input_format $([ "$fmt" = nv12 ] && echo nv12 || echo yuyv422) -video_size $mode -framerate $fr" \
			"-i $vdev -f alsa -channels 2 -sample_rate 48000 -i $pcm -t $secs -map 0:v -map 1:a" \
			"-c:v libx264 -preset ultrafast -qp 0 -c:a pcm_s16le -copyts -start_at_zero -y '$f'" ;;
	gst)
		echo "GST_REGISTRY_UPDATE=no $wrap timeout -s INT $secs gst-launch-1.0 -q -e v4l2src device=$vdev !" \
			"video/x-raw,format=$([ "$fmt" = nv12 ] && echo NV12 || echo YUY2),width=$w,height=$h,framerate=$fr$([ "$rate" = 59.94 ] || echo /1) !" \
			"$([ "$fmt" = nv12 ] && echo 'videoconvert ! video/x-raw,format=I420 !')" \
			"queue max-size-buffers=0 max-size-bytes=0 max-size-time=3000000000 ! mux." \
			"alsasrc device=$pcm ! audio/x-raw,format=S16LE,rate=48000,channels=2 ! queue ! mux." \
			"matroskamux name=mux ! filesink location='$f'" ;;
	vlc)
		# VLC takes a v4l2:// location up to its first ':' as the device
		# (modules/access/v4l2/v4l2.c ParseMRL, 3.0.20), and the by-path
		# name has ':' in it; with no device before the ':' it would open
		# its default, /dev/video0. So the node the by-path link resolves
		# to, in the location and as --v4l2-dev
		echo "$wrap timeout -s INT $((secs + 15)) cvlc -I dummy -q \"v4l2://\$(readlink -f $vdev)\" --v4l2-dev=\"\$(readlink -f $vdev)\"" \
			"--v4l2-chroma=$([ "$fmt" = nv12 ] && echo NV12 || echo YUYV) --v4l2-width=$w --v4l2-height=$h --v4l2-fps=$rate" \
			"--input-slave='alsa://$pcm' --sout '#transcode{vcodec=h264,venc=x264{qp=0,preset=ultrafast},acodec=s16l,channels=2,samplerate=48000}:std{access=file,mux=mkv,dst=$f}'" \
			"--run-time=$secs vlc://quit" ;;
	esac
}
# the test source in MODE at RATE with its bursts, and the card's audio on
apps_source() {
	local i d
	wait_connected 15 || return 1
	src_on "$1" "$2" || return 1
	for i in $(seq 30); do
		"$ROOT/tools/testsrc/avsync.sh" --pattern "$OUT" "$1" "$2" >/dev/null 2>&1 && break
		sleep 0.5
	done
	[ "$i" -lt 30 ] || return 1
	for i in $(seq 40); do
		d=$(aud_dbg)
		grep -q 'it6805 audio on' <<< "$d" && grep -q '(48000 Hz)' <<< "$d" && return 0
		sleep 0.25
	done
	return 1
}
# one capture checked: app fmt mode rate [ref]
apps_capture() {
	local app=$1 fmt=$2 mode=$3 rate=$4 ref=${5:-} f out rc name st
	name=apps-$app-${mode#*x}p$rate-$fmt
	f=$APPS_DIR/$name.mkv
	ev "apps: $app records $mode@$rate $fmt"
	vm "$(app_cmd "$app" "$fmt" "$mode" "$rate" "$APPS_SECS" "$f") > $APPS_DIR/$name.err 2>&1"
	rc=$?
	# ffmpeg and VLC end by themselves; gst-launch by timeout's SIGINT (EOS)
	[ "$app" = gst ] && [ "$rc" = 124 ] && rc=0
	# the driver's counters for the app's stream (kept after its stop):
	# underruns, the times no buffer was queued, so the frame went
	# uncaptured: the application returned its buffers late
	st=$(vm "sudo cat $dbgdir/video" 2>/dev/null | sed -n 's/^stats: //p')
	out=$(vm "python3 $W/app-check.py '$f' $mode --fps $rate ${ref:+--ref $ref}" 2>&1)
	echo "  $name: exit $rc$(vm "[ -s $APPS_DIR/$name.err ] && echo ': ' && tail -c 300 $APPS_DIR/$name.err | tr '\n' ' '")"
	av_results "$name" "$out"
	[ -z "$st" ] || echo "  INFO $name-driver the driver's stream: $(grep -oE '(frames|underruns) [0-9]+' <<< "$st" | paste -sd' ') (an underrun: no buffer queued, the frame uncaptured; the application was late returning its buffers)"
	vm "rm -f '$f' $APPS_DIR/$name.err"
}
# one change while the app records 30 s, 8 s in: app kind. An APP line
# says what it did; RESULT FAIL when it does not carry on through a change
# in the same timings (sleep, relock, rate: the driver restarts the stream
# itself), or a restart at the new mode does not bring it back
apps_change() {
	local app=$1 kind=$2 name f pid t0 t_ch t_back t_end rc sub out left verdict back ok i el
	local mode0=1920x1080 rate0=60 mode1=1920x1080 rate1=60
	name=apps-$app-change-$kind
	f=$APPS_DIR/$name.mkv
	case $kind in
	rate) rate1=59.94 ;;
	res) mode1=1280x720 rate1=59.94 ;;
	esac
	apps_source $mode0 $rate0 || { result "$name" FAIL "(the test source did not start)"; return; }
	ev "apps: $app records 30 s across a change: $kind"
	t0=$(date +%s.%N)
	vm "$(app_cmd "$app" yuyv $mode0 $rate0 30 "$f" "strace -f -qq -o $APPS_DIR/$name.strace -e trace=ioctl") \
		> $APPS_DIR/$name.err 2>&1" &
	pid=$!
	sleep 8
	t_ch=$(date +%s.%N)
	ev "apps: change $kind"
	case $kind in
	sleep) src_off; sleep 5; apps_source $mode1 $rate1 ;;
	relock)
		# vm() closes the test players before an EDID set
		vm "v4l2-ctl -d $vdev --set-edid=file=$APPS_DIR/edid-other.bin,format=raw" > /dev/null
		sleep 1; wait_connected 15; apps_source $mode1 $rate1 ;;
	*) apps_source $mode1 $rate1 ;;
	esac
	# the source shows again (or in its new mode) from here: the frames
	# from 3 s on tell whether the app carried on (after a sleep the output
	# was off 5 s, and the source takes a few seconds more to show)
	t_back=$(date +%s.%N)
	# to the end of its 30 s, 5 s more at most
	for i in $(seq 400); do
		kill -0 $pid 2>/dev/null || break
		[ "$(echo "$(date +%s.%N) - $t0 > 35" | bc)" = 1 ] && break
		sleep 0.1
	done
	t_end=$(date +%s.%N)
	el=$(echo "$t_end - $t0" | bc)
	if kill -0 $pid 2>/dev/null; then
		left="still running after ${el%.*} s: stopped"
		vm "pkill -INT -f '$f'"; sleep 3; vm "pkill -KILL -f '$f'"
		wait $pid; rc=$?
	else
		wait $pid; rc=$?
		if [ "$(echo "$el < 28" | bc)" = 1 ]; then
			left="ended $(printf '%+.1f' "$(echo "$t_end - $t_ch" | bc)") s after the change, exit $rc"
		else
			left="ran its 30 s (exit $rc)"
		fi
	fi
	sub=$(vm "grep -c 'VIDIOC_SUBSCRIBE_EVENT.*= 0$' $APPS_DIR/$name.strace;
		grep -c 'VIDIOC_DQEVENT.*= 0$' $APPS_DIR/$name.strace" | paste -sd' ')
	out=$(vm "python3 $W/app-check.py '$f' $mode0 --change $(echo "$t_back - $t0 - 0.5" | bc)" 2>&1 |
		grep -E '^CHANGE|^RESULT media')
	case "$out" in
	*"(settled)"*": live"*) verdict="carried on" ;;
	*": frozen"*) verdict="froze (one frame repeated)" ;;
	*": black"*) verdict="black after the change" ;;
	*": jumpy"*) verdict="jumpy frames after the change" ;;
	*": other"*) verdict="another picture after the change" ;;
	*) verdict="no frames after the change" ;;
	esac
	case $left in ended*) [ "$verdict" = "carried on" ] || verdict="errored out ($verdict)" ;; esac
	back=""
	if [ "$verdict" != "carried on" ]; then
		vm "$(app_cmd "$app" yuyv $mode1 $rate1 6 "$APPS_DIR/$name-again.mkv") > /dev/null 2>&1"
		back=$(vm "python3 $W/app-check.py '$APPS_DIR/$name-again.mkv' $mode1 --change 0" 2>&1 | grep '^CHANGE')
		case "$back" in
		*"(settled)"*": live"*) back="a restart at $mode1@$rate1 brings it back" ;;
		*) back="a restart at $mode1@$rate1 does NOT bring it back (${back:-no file})" ;;
		esac
	fi
	echo "  APP $app $kind: events subscribed ${sub%% *}x, dequeued ${sub##* }x; $left; $verdict${back:+; $back}"
	echo "    $(tr '\n' ' ' <<< "$out")"
	echo "    stderr: $(vm "tail -c 400 $APPS_DIR/$name.err" | tr '\n' ' ')"
	echo "    driver: $(hdmi_dbg | grep -E '^input:' | head -1)"
	# a new resolution ends every app's stream (the driver ends it); a new
	# frame rate is a caps change for GStreamer's fixed-caps pipeline into
	# Matroska, which cannot take one: then a restart must bring it back
	if [ "$kind" = res ] || { [ "$kind" = rate ] && [ "$app" = gst ]; }; then
		ok=$([ "$verdict" = "carried on" ] || [[ $back == *"brings it back"* ]]; echo $?)
	else
		ok=$([ "$verdict" = "carried on" ]; echo $?)
	fi
	check "$name" "$ok" "($left; $verdict${back:+; $back}; events subscribed ${sub%% *}x, dequeued ${sub##* }x)"
	vm "rm -f '$f' '$APPS_DIR/$name-again.mkv' $APPS_DIR/$name.strace $APPS_DIR/$name.err"
	if [ "$kind" = relock ]; then
		vm "v4l2-ctl -d $vdev --set-edid=file=$APPS_DIR/edid-default.bin,format=raw" > /dev/null
		sleep 1; wait_connected 15
	fi
}
step_apps() {
	local app why ver m mode rate fmt ref
	vm "mkdir -p $APPS_DIR" || { result apps FAIL "(cannot create $APPS_DIR)"; return; }
	vm "v4l2-ctl -d $vdev --get-edid=file=$APPS_DIR/edid-default.bin,format=raw >/dev/null &&
		python3 -c \"import sys; d=bytearray(open(sys.argv[1],'rb').read()); d[0x0c]^=0x5a; d[0x7f]=-sum(d[0:0x7f]) & 0xff; open(sys.argv[2],'wb').write(d)\" $APPS_DIR/edid-default.bin $APPS_DIR/edid-other.bin"
	for app in $APPS; do
		why=$(app_missing "$app")
		if [ -n "$why" ]; then
			result "apps-$app" SKIP "($why)"
			continue
		fi
		echo "  $app $(app_version "$app")"
	done
	# the captures: per mode one source session, the driver's offset first
	for m in "1920x1080 60 yuyv nv12" "1280x720 59.94 yuyv"; do
		read -r mode rate fmt <<< "${m% nv12}"
		apps_source "$mode" "$rate" || { result "apps-source-${mode#*x}p$rate" FAIL "(avsync.sh --pattern)"; continue; }
		sleep 3
		driver_ref "apps-driver-${mode#*x}p$rate" "$APPS_SECS"
		for app in $APPS; do
			[ -z "$(app_missing "$app")" ] || continue
			for fmt in yuyv $([ "${m##* }" = nv12 ] && echo nv12); do
				apps_capture "$app" "$fmt" "$mode" "$rate" "$ref"
			done
		done
	done
	# the changes
	for app in $APPS; do
		[ -z "$(app_missing "$app")" ] || continue
		for kind in sleep relock rate res; do
			apps_change "$app" "$kind"
		done
	done
	vm "rm -f $APPS_DIR/edid-default.bin $APPS_DIR/edid-other.bin; rmdir $APPS_DIR" 2>/dev/null
	"$ROOT/tools/testsrc/avsync.sh" --off
	src_on 1920x1080 60
}

# ---- the Roku (GC573_SOURCE=roku, host-local only) ----
# M6. The source is the Roku, through the HDCP filter: the user moves the
# card's input cable to it. tools/roku/ecp.py drives it over the LAN. Its
# address is kept outside the repo, in ~/.config/gc573/roku (mode 0600) or
# GC573_ROKU. The Roku plays tools/roku/pattern-video.sh's file (the
# counter, the flash and the burst), which tools/roku/serve.py serves from
# this machine for the run's length only.
# Nothing in this mode touches DVI-D-0: src_on, src_off, av_on and
# colour_set refuse, and colour_restore does nothing.
# Actions on the Roku (keypresses, playing a URL) need GC573_ROKU_GO=1,
# the go to use it, since the user may be using it. Without it only
# rokulock, rokucompliance and q25 run, passively.
# The logs keep numbers, and checks of our own pattern video only: never a
# picture or a recording of what the Roku shows, nor its identifiers.
ECP=$ROOT/tools/roku/ecp.py
ROKU_DIR=${GC573_ROKU_DIR:-$HOME/gc573-roku}
ROKU_SECS=${GC573_ROKU_SECS:-60}
# rokumodes: seconds of gc573-aud -V after each EDID set, and how many such
# captures (each a stream start of its own)
ROKU_DRV_SECS=${GC573_ROKU_DRV_SECS:-10}
ROKU_DRV_REPS=${GC573_ROKU_DRV_REPS:-1}
# the pattern video's frame rate: the Roku's output, 59.94 Hz (a 60 fps
# file makes its player drop frames); GC573_ROKU_FPS as ffmpeg takes it
ROKU_FPS=${GC573_ROKU_FPS:-60000/1001}
Q25_SECS=${GC573_Q25_SECS:-180}
ROKU_URL_FILE="" roku_serve_pid="" roku_served="" roku_halt=0
# The steps run in main's subshell (piped to tee), and the EXIT trap in the
# shell above it: what the trap needs (the server's pid; whether we played)
# goes in files in ROKU_RUN, made below in Roku mode
ROKU_RUN=""
ecp() { python3 "$ECP" "$@"; }
roku_go() { [ "${GC573_ROKU_GO:-0}" = 1 ]; }
roku_skip() { result "$1" SKIP "(needs GC573_ROKU_GO=1: it $2)"; }
# the pattern video for SECS seconds, made once and checked
# (tools/roku/check-video.py) in ROKU_DIR; prints its path
roku_video() {
	local f tag
	case $ROKU_FPS in 60000/1001) tag=-59.94 ;; 60) tag="" ;; *) tag=-${ROKU_FPS//\//_} ;; esac
	f=$ROKU_DIR/pattern-$1s$tag.mp4
	mkdir -p "$ROKU_DIR" || return 1
	if [ ! -s "$f" ]; then
		echo "  making $f ($1 s of the pattern video at $ROKU_FPS fps)" >&2
		nice "$ROOT/tools/roku/pattern-video.sh" "$f.new.mp4" "$1" 1920 1080 "$ROKU_FPS" 60 > /dev/null &&
			python3 "$ROOT/tools/roku/check-video.py" "$f.new.mp4" > "$f.check" &&
			mv "$f.new.mp4" "$f" || { cat "$f.check" >&2; rm -f "$f.new.mp4"; return 1; }
	fi
	echo "$f"
}
# serve FILE to the Roku until the run ends (or roku_serve_stop); the URL
# goes to a 0600 file, never to a log
roku_serve_start() {
	local i
	ROKU_URL_FILE=$(mktemp -u /tmp/gc573-roku-url.XXXXXX)
	# not on main's stdout: tee would wait for the server to end (it logs
	# its requests to GC573_EVENT_LOG itself)
	python3 "$ROOT/tools/roku/serve.py" "$1" --url-file "$ROKU_URL_FILE" \
		--secs $((OBSSOAK_SECS + 14400)) --pid $$ > /dev/null 2> "$ROKU_RUN/serve.err" &
	roku_serve_pid=$!
	echo "$roku_serve_pid" > "$ROKU_RUN/server.pid"
	for i in $(seq 50); do
		[ -s "$ROKU_URL_FILE" ] && { roku_served=$1; return 0; }
		sleep 0.1
	done
	sed 's/^/  serve.py: /' "$ROKU_RUN/serve.err" 2>/dev/null | head -5
	roku_serve_stop
	return 1
}
# here or from the EXIT trap, where the server is no child of the shell
roku_serve_stop() {
	local pid i
	roku_served=""
	pid=${roku_serve_pid:-$(cat "$ROKU_RUN/server.pid" 2>/dev/null)}
	roku_serve_pid=""
	rm -f "$ROKU_RUN/server.pid"
	[ -n "$pid" ] || return 0
	kill "$pid" 2>/dev/null
	for i in $(seq 50); do
		kill -0 "$pid" 2>/dev/null || return 0
		sleep 0.1
	done
}
roku_play() {
	: > "$ROKU_RUN/played"
	ecp play "$(cat "$ROKU_URL_FILE")"
}
# awake: a Home keypress unless its power mode is PowerOn
roku_wake() {
	[ "$(ecp power 2>/dev/null)" = PowerOn ] && return 0
	ecp key Home && sleep 3
}
# frames of a 1 s capture whose counter reads: the pattern is on the card
roku_counters() {
	vm "sudo $W/gc573-aud -D $pcm -t 1 -v -V $vdev -P -o /dev/null 2>/dev/null" | grep -c '^V .* c=[0-9]'
}
# SECS: the pattern video (of SECS seconds) playing and on the card
# The safety net: if our video does not show on the card (the counters
# read), the Roku acted on may not be the cabled one, or Play on Roku
# does not work. The run then sends nothing more to the Roku (roku_halt)
# but stop-ours at its end
roku_source_on() {
	local f i
	[ "$roku_halt" = 0 ] ||
		{ echo "  no action on the Roku: halted earlier in this run"; return 1; }
	f=$(roku_video "$1") || return 1
	# a step that needs a longer video than the one served gets it
	[ "$roku_served" = "$f" ] || { roku_serve_stop; roku_serve_start "$f"; } || return 1
	roku_wake
	roku_play || { roku_halt=1; return 1; }
	for i in $(seq 40); do
		locked && [ "$(roku_counters)" -gt 30 ] && return 0
		sleep 1
	done
	roku_halt=1
	echo "  our video did not show on the card within 40 s ($(roku_input); $(roku_counters) of 60 counters read in 1 s): no more actions on the Roku in this run"
	return 1
}
# the end of a Roku run: the server stopped; with the go, our video
# stopped (Home) if it still plays (ecp.py stop-ours), and Home if this
# run's PowerOff left the Roku asleep (roku_key). Nothing else: the user
# restores the Roku's state themselves
roku_end() {
	roku_serve_stop
	! roku_go || [ ! -e "$ROKU_RUN/played" ] ||
		ecp stop-ours 2>&1 | sed 's/^/  /'
	! roku_go || [ ! -e "$ROKU_RUN/asleep" ] ||
		{ echo "  the Roku was left asleep by this run: Home"; ecp key Home 2>&1 | sed 's/^/  /'; }
	[ -z "$ROKU_RUN" ] || rm -rf "$ROKU_RUN"
}
roku_rate() {	# 60 or 59.94 from QUERY_DV_TIMINGS
	local q
	q=$(query)
	if grep -q 'framerate is reduced' <<< "$q"; then echo 59.94; else echo 60; fi
}
roku_timings() { query | grep -oE 'Active width: [0-9]+|Active height: [0-9]+|Pixelclock: [0-9]+ Hz' | paste -sd, -; }
roku_input() { hdmi_dbg | grep '^input:' | grep -oE 'power [01] signal [01] locked [01]|colour [0-9] vic [0-9]+ full_range [01] enc [0-9] dvi [01]' | paste -sd' ' -; }

# ---- any picture: the Roku's own (its home screen, its screen saver),
# when it cannot play our pattern (Play on Roku is not on the 4850X). The
# driver's verdict comes from its own numbers (sequence numbers, frame
# intervals, counters), never from the picture; of the picture only
# numbers are kept (luma), and recordings are deleted after the analysis

# the AVI InfoFrame the IT6805 has now (debugfs hdmi)
roku_avi() {
	local a
	a=$(hdmi_dbg | sed -n 's/^it6805: mode .* avi \([0-9a-f ]*[0-9a-f]\) bus .*/\1/p')
	echo "${a:-none}"
}
# what the card sees: the input line, QUERY_DV_TIMINGS, the AVI
roku_card() { echo "$(roku_input); $(roku_reported); AVI $(roku_avi)"; }
# roku_card for SECS s, a line at each change, with seconds from now
roku_watch() {
	local t0 now c last=""
	t0=$(date +%s)
	while now=$(date +%s); [ $((now - t0)) -lt "$1" ]; do
		c=$(roku_card)
		[ "$c" = "$last" ] || echo "  +$((now - t0)) s: $c"
		last=$c
		sleep 1
	done
}
# KEY on the saved Roku (the go). 0: sent; 1: refused by the Roku (an HTTP
# error); 2: no answer, or no answer earlier in this run (roku_halt): the
# Roku has stopped answering ECP, and nothing more goes to it (no retry).
# The error in roku_err. PowerOff marks the Roku asleep for the run's end
# (roku_end: Home); Home clears it
roku_err=""
roku_key() {
	[ "$roku_halt" = 0 ] || { roku_err="no action on the Roku: halted earlier in this run"; return 2; }
	if roku_err=$(ecp key "$1" 2>&1); then
		case $1 in
		PowerOff) : > "$ROKU_RUN/asleep" ;;
		Home) rm -f "$ROKU_RUN/asleep" ;;
		esac
		return 0
	fi
	roku_err=${roku_err#ecp: }
	case $roku_err in *'no answer'*) roku_halt=1; return 2 ;; esac
	return 1
}
# the saved Roku's power mode in roku_pm (else the error; no answer halts)
roku_pm=""
roku_power() {
	roku_pm=$(ecp power 2>&1) && return 0
	roku_pm=${roku_pm#ecp: }
	case $roku_pm in *'no answer'*) roku_halt=1 ;; esac
	return 1
}
# NAME SECS: SECS s of gc573-aud -V at the input's timings, the driver's
# own numbers (live-av.py): duration, xruns, the audio rate and gaps, and
# video (no sequence gap, every frame interval within half a period). The
# pattern's checks (bursts, channels, A/V offset) do not apply: without
# our pattern the A/V offset is not measurable. INFO: how much the picture
# moved (each frame's mean luma over a 16 x 9 grid)
roku_drv() {
	local out rp rc
	# the driver's frame-interrupt ring meanwhile (32 interrupts, 0.53 s at
	# 60 Hz: read every 0.3 s it misses none): its times are the buffers'
	# timestamps (taken in the hard IRQ), with each interrupt's slot status
	# and how many buffers it completed, also for the ones that completed none
	( while :; do
		vm "sudo cat $dbgdir/video" | awk '/^events/ { f = 1; next } f && $1 ~ /^[0-9]+$/'
		sleep 0.3
	done ) > "$W/drv-ring.txt" 2> /dev/null &
	rp=$!
	vm "sudo $W/gc573-aud -D $pcm -t $2 -v -V $vdev -o $W/drv.raw > $W/drv.txt 2>&1"
	rc=$?
	kill "$rp" 2> /dev/null
	wait "$rp" 2> /dev/null
	check "$1-capture" "$rc" "($(grep -E '^(PARAMS|RESULT)' "$W/drv.txt" | tr '\n' ' '))"
	out=$(python3 "$W/live-av.py" "$W/drv.txt" "$W/drv.raw" --min-secs $(($2 * 9 / 10)) 2>&1)
	av_results "$1" "$(grep -E '^RESULT +(duration|xruns|rate|gaps|video) ' <<< "$out")"
	# the frame intervals more than 10 % off their median: when, where, how
	# long, and the sequence step (numbers only)
	if ! grep -q '^RESULT video .* 0 by more than 10 %' <<< "$out"; then
		sort -u "$W/drv-ring.txt" > "$W/drv-ring.u"
		awk 'function ph(k) { return (k < 1 || k > n) ? "-" : sprintf("%+.3f", (ts[k] - ts[1]) / 1e6 - (k - 1) * med) }
			FNR == NR { r[++nr] = $0; rt[nr] = $1; next }
			/^A / && !a0 { split($4, t, "="); a0 = t[2] }
			/^V / { n++; split($2, q, "="); split($3, t, "="); s[n] = q[2]; ts[n] = t[2] }
			END {
				for (i = 2; i <= n; i++) { d[i] = (ts[i] - ts[i - 1]) / 1e6; x[i - 1] = d[i] }
				m = n - 1
				for (i = 2; i <= m; i++) { v = x[i]; for (j = i - 1; j >= 1 && x[j] > v; j--) x[j + 1] = x[j]; x[j + 1] = v }
				med = x[int((m + 1) / 2)]
				printf "  the first frame at 0; the first audio read at %+.3f s\n", (a0 - ts[1]) / 1e9
				for (i = 2; i <= n; i++) if (d[i] > med * 1.1 || d[i] < med * 0.9) {
					printf "  interval off: frame %d of %d (%.3f s in), seq %d -> %d, %.3f ms (median %.3f), neighbours %.3f and %.3f ms\n",
						i, n, (ts[i] - ts[1]) / 1e9, s[i - 1], s[i], d[i], med, (i > 2 ? d[i - 1] : 0), (i < n ? d[i + 1] : 0)
					# the time of each frame against the median cadence from the
					# first: a lasting step is a phase change, not a lost frame
					printf "    phase against the median cadence, frames %d to %d: %s ms\n", i - 2, i + 1, ph(i - 2) " " ph(i - 1) " " ph(i) " " ph(i + 1)
					lo = ts[i > 3 ? i - 3 : 1] - 1e6; hi = ts[i + 2 <= n ? i + 2 : n] + 1e6; k = 0
					for (j = 1; j <= nr; j++) if (rt[j] >= lo && rt[j] <= hi) {
						split(r[j], e, " ")
						printf "    ring: %+.3f ms from frame %d, status %s ctrl %s done %s armed %s\n", (e[1] - ts[i - 1]) / 1e6, i - 1, e[2], e[3], e[4], e[5]
						k++
					}
					if (!k) print "    ring: no interrupt of that time read"
				}
			}' "$W/drv-ring.u" "$W/drv.txt"
		echo "  the driver after: $(vm "sudo cat $dbgdir/video" | grep -E '^(stream|stats):' | paste -sd';' -)"
	fi
	echo "  INFO $1-picture $(awk '/^V / { y = substr($4, 3) + 0; n++; if (n > 1 && y != p) c++; p = y; v[y] = 1 }
		END { k = 0; for (i in v) k++; printf "%d frames; their grid luma took %d values and changed between %d of %d frame pairs", n, k, c, n - 1 }' "$W/drv.txt")"
	vm "rm -f $W/drv.raw $W/drv.txt $W/drv-ring.txt $W/drv-ring.u"
}
# the driver's video counters now (debugfs video "stats:")
vid_stats() { vm "sudo cat $dbgdir/video" | sed -n 's/^stats: //p'; }
# the driver's stream is running and delivering: its frame count moves
# over 2 s (a reader, OBS, takes and gives back its buffers)
vid_moving() {
	local f0 f1
	vm "sudo cat $dbgdir/video" | grep -q '^stream: running 1 ' || return 1
	f0=$(vid_stats | grep -oE '\bframes [0-9]+')
	sleep 2
	f1=$(vid_stats | grep -oE '\bframes [0-9]+')
	[ -n "$f1" ] && [ "$f1" != "$f0" ]
}
# the driver's last 32 frame interrupts (debugfs video "events", the
# stream's): their intervals against their median. Read while a stream
# runs in a steady state (across a loss or a restart the ring holds the gap)
roku_ring() {
	vm "sudo cat $dbgdir/video" | awk '/^events/ { f = 1; next } f && $1 ~ /^[0-9]+$/ { t[n++] = $1 }
		END {
			m = n - 1
			if (m < 1) { print "0 intervals"; exit }
			for (i = 1; i <= m; i++) { d[i] = (t[i] - t[i - 1]) / 1e6; s[i] = d[i] }
			for (i = 2; i <= m; i++) { v = s[i]; for (j = i - 1; j >= 1 && s[j] > v; j--) s[j + 1] = s[j]; s[j + 1] = v }
			med = s[int((m + 1) / 2)]; bad = 0
			for (i = 1; i <= m; i++) if (d[i] < med / 2 || d[i] > med * 1.5) bad++
			printf "%d intervals, median %.3f ms, %.3f to %.3f, %d off by more than half a period\n", m, med, s[1], s[m], bad }'
}
roku_ring_ok() { grep -q ' 0 off by more than half a period$' <<< "$1" && [ "${1%% *}" -ge 30 ]; }
# the driver's error counters between two vid_stats lines (0: none moved)
vid_errors() {
	awk -v a="$1" -v b="$2" 'BEGIN { n = split(a, x, " "); split(b, y, " ")
		for (i = 1; i < n; i += 2) {
			# a new stream starts its counters again
			d = y[i + 1] - x[i + 1]; if (d < 0) d = y[i + 1]
			if (x[i] ~ /^(unarmed|order|bad_status)$/ && d) { printf "%s +%d ", x[i], d; e = 1 }
		}
		exit e }'
}
obsany() { python3 "$ROOT/tests/obs-any.py" "$@"; }

# rokulock: the Roku's input locks; its timings, colour and range as the
# driver reports them, and the Roku's model and software. Passive without
# the go (the Roku must be on); with it, a Home keypress wakes it first
step_rokulock() {
	local t d
	echo "  Roku: $(ecp info 2>&1)"
	! roku_go || roku_wake
	t=$(time_to_lock 30)
	d=$(roku_input)
	query | grep -E 'Active width|Active height|Pixelclock|Frame format|CTA|Flags' | sed 's/^/  /'
	check roku-lock "$([ "$t" != none ] && grep -q 'power 1 signal 1 locked 1' <<< "$d"; echo $?)" \
		"(locked within $t ms; $(roku_timings); $d)"
}

step_rokucompliance() {
	local out
	time_to_lock 30 > /dev/null
	vm "v4l2-ctl -d $vdev --set-dv-bt-timings query >/dev/null"
	out=$(vm "v4l2-compliance -d $vdev -s 2>&1")
	echo "$out" | grep -E 'fail|warn|Total for' | sed 's/^/  /'
	check roku-compliance "$(grep -q 'Failed: 0, Warnings: 0' <<< "$out"; echo $?)" \
		"($(grep 'Total for' <<< "$out"))"
}

# The colour patches of one YUYV frame of the pattern video (numbers only):
# mean Y, Cb, Cr per patch against BT.709 limited range, within 12 codes
roku_patches() {
	local q
	vm "sudo $W/gc573-cap -d $vdev -L 10 -f YUYV -n 30 -o $W/roku-frame > /dev/null 2>&1" &&
		[ -s "$W/roku-frame.YUYV" ] || { echo "RESULT patches FAIL (no frame)"; return; }
	q=$(query)
	python3 - "$W/roku-frame.YUYV" "$(sed -n 's/.*Active width: //p' <<< "$q")" \
		"$(sed -n 's/.*Active height: //p' <<< "$q")" <<'PY'
import sys
w, h = int(sys.argv[2]), int(sys.argv[3])
d = open(sys.argv[1], 'rb').read()
want = [('black', 16, 128, 128), ('white', 235, 128, 128), ('grey', 126, 128, 128),
        ('red', 63, 102, 240), ('green', 173, 42, 26), ('blue', 32, 240, 118)]
pw, ph, py = w // 8, h // 4, h // 8
worst, txt = 0, []
for i, (name, y0, cb0, cr0) in enumerate(want):
    x0 = w // 16 + i * (pw + w // 32)
    ys, cbs, crs = [], [], []
    for y in range(py + ph // 4, py + 3 * ph // 4, 4):
        row = d[y * w * 2:(y + 1) * w * 2]
        for x in range(x0 + pw // 4, x0 + 3 * pw // 4, 4):
            x &= ~1
            ys.append(row[2 * x]); cbs.append(row[2 * x + 1]); crs.append(row[2 * x + 3])
    m = [sum(v) / len(v) for v in (ys, cbs, crs)]
    worst = max(worst, abs(m[0] - y0), abs(m[1] - cb0), abs(m[2] - cr0))
    txt.append(f'{name} {m[0]:.0f}/{m[1]:.0f}/{m[2]:.0f}')
print(f"RESULT patches {'PASS' if worst <= 12 else 'FAIL'} (Y/Cb/Cr: {', '.join(txt)}; worst {worst:.0f} codes from BT.709 limited range)")
PY
	vm "rm -f $W/roku-frame.*"
}

# rokucapture: the pattern video on the Roku (go). GC573_ROKU_SECS (60) of
# gc573-aud -V -P: the driver loses nothing (live-av.py --exact; the
# Roku's own repeats and skips are INFO), the bursts on the right channels,
# the A/V offset (flash against burst), and the colour patches
step_rokucapture() {
	local out rate
	roku_go || { roku_skip roku-capture "plays our pattern video on the Roku"; return; }
	roku_source_on 3600 || { result roku-capture-source FAIL "(the pattern video on the Roku and the card: ecp.py play)"; return; }
	rate=$(roku_rate)
	echo "  $(roku_timings), $rate Hz; $(roku_input)"
	sleep 3
	vm "sudo $W/gc573-aud -D $pcm -t $ROKU_SECS -v -V $vdev -P -o $W/roku.raw > $W/roku.txt 2>&1"
	out=$(vm "python3 $W/live-av.py $W/roku.txt $W/roku.raw --exact pattern $rate")
	vm "rm -f $W/roku.raw"
	av_results roku-capture "$out"
	av_results roku "$(roku_patches)"
}

# rokuobs: OBS (the user's, started minimized, its sources checked) on the
# Roku's pattern through obs-websocket: screenshots (counter and patches),
# the level meters (the bursts), a 60 s recording's picture and A/V offset
step_rokuobs() {
	local out f
	roku_go || { roku_skip roku-obs "plays our pattern video on the Roku"; return; }
	roku_source_on 3600 || { result roku-obs-source FAIL "(the pattern video on the Roku and the card)"; return; }
	obs_up || { result roku-obs-start FAIL "(OBS minimized, with the sources expected)"; obs_down; return; }
	sleep 3
	av_results roku-obs "$(roku_obsev shots 10 2>&1)"
	av_results roku-obs "$(roku_obsev meters 20 2>&1)"
	out=$(obsc "record 60")
	f=$(sed -n 's/^RECORDING //p' <<< "$out")
	check roku-obs-record "$([ -n "$f" ]; echo $?)" "($(grep '^STATS' <<< "$out"))"
	if [ -n "$f" ]; then
		av_results roku-obs "$(GC573_SOURCE=roku python3 "$ROOT/tests/obs-events.py" recheck "$f" --every 5 2>&1)"
		av_results roku-obs-rec "$(python3 "$ROOT/tests/obs-av.py" "$f" --box 0.70,0.88,0.92,0.92 --min-secs 55 2>&1)"
		rm -f "$f"
	fi
	obs_down
}
# tests/obs-events.py on the Roku's picture
roku_obsev() {
	GC573_SOURCE=roku GC573_ROKU_URL_FILE=$ROKU_URL_FILE python3 "$ROOT/tests/obs-events.py" "$@"
}

# The Roku's input lost, then back: seconds to each, from now (limits
# LOSE, BACK s); prints "lost back" (- for never)
roku_loss_back() {
	local t0 lost=- back=- i
	t0=$(date +%s%N)
	for i in $(seq $(($1 * 4))); do
		locked || { lost=$(( ($(date +%s%N) - t0) / 100000000 )); break; }
		sleep 0.25
	done
	if [ "$lost" != - ]; then
		for i in $(seq $(($2 * 4))); do
			locked && { back=$(( ($(date +%s%N) - t0) / 100000000 )); break; }
			sleep 0.25
		done
	fi
	# tenths of a second as seconds
	for i in lost back; do
		[ "${!i}" = - ] || printf -v "$i" '%d.%d' $((${!i} / 10)) $((${!i} % 10))
	done
	echo "$lost $back"
}

# rokusleep (the go): the Roku asleep and awake, PowerOff, then Home. Any
# picture (the pattern is not needed): what the card sees at each step (the
# input line, QUERY_DV_TIMINGS, the AVI InfoFrame; the Roku's power mode),
# a line at each change; the driver's own numbers in 10 s of gc573-aud -V
# before and after (roku_drv). A PowerOff the Roku refuses (an HTTP error)
# skips the step with nothing more sent. So does a PowerOff after which the
# card keeps its signal for 30 s and the Roku stays in PowerOn: sleep and
# wake are not exercised (the 4850X ignores ECP PowerOff), and the capture
# after is a plain one. The driver's part when the Roku sleeps: the lock
# after Home and a clean capture
step_rokusleep() {
	local tm0 a0 t w
	roku_go || { roku_skip roku-sleep "puts the Roku to sleep and wakes it"; return; }
	time_to_lock 30 > /dev/null || { result roku-sleep SKIP "(no input before the step: $(roku_card))"; return; }
	roku_drv roku-sleep-before 10
	roku_power
	tm0=$(roku_timings) a0=$(roku_avi)
	echo "  before: the Roku's power mode $roku_pm; the card: $(roku_card)"
	kmsg_mark rokusleep
	roku_key PowerOff || { result roku-sleep SKIP "(PowerOff: $roku_err; nothing more sent in this step)"; return; }
	echo "  PowerOff sent; the card for 30 s, a line at each change:"
	w=$(roku_watch 30)
	echo "$w"
	roku_power || { result roku-sleep FAIL "(the Roku stopped answering ECP after PowerOff: $roku_pm; no more actions on it)"; return; }
	echo "  30 s after PowerOff: the Roku's power mode $roku_pm"
	if ! grep -qE 'signal 0|locked 0' <<< "$w" && [ "$roku_pm" = PowerOn ]; then
		# it did not sleep: nothing of ours to undo, no Home
		rm -f "$ROKU_RUN/asleep"
		result roku-sleep SKIP "(not exercised: the card kept the Roku's signal for 30 s after PowerOff, and the Roku reports power mode $roku_pm: this player ignores ECP PowerOff; nothing more sent)"
		roku_drv roku-sleep-after 10
		return
	fi
	roku_key Home || { result roku-sleep-wake FAIL "(Home: $roku_err)"; return; }
	echo "  Home sent; the card for 20 s after the lock, a line at each change:"
	t=$(time_to_lock 60)
	roku_watch 20
	roku_power
	echo "  awake: the Roku's power mode $roku_pm"
	kmsg_since rokusleep | grep -E 'gc573 .*(HDMI|IT6805)' | sed 's/^/  | /'
	check roku-sleep-relock "$([ "$t" != none ] && locked; echo $?)" \
		"(locked $t ms after Home at $(roku_timings) (before: $tm0); AVI $(roku_avi) (before: $a0); the Roku's power mode $roku_pm)"
	roku_drv roku-sleep-after 10
}

# rokureboot: the Roku restarted (GC573_ROKU_REBOOT_KEYS: the keypresses to
# its System restart; ECP has no command for it): the input goes and comes
# back within 3 minutes, and the pattern plays on the card again
step_rokureboot() {
	local lb
	roku_go || { roku_skip roku-reboot "restarts the Roku"; return; }
	[ -n "${GC573_ROKU_REBOOT_KEYS:-}" ] ||
		{ result roku-reboot SKIP "(no GC573_ROKU_REBOOT_KEYS: ECP has no restart, and the keys to the Roku's System restart would be blind menu navigation)"; return; }
	roku_source_on 3600 || { result roku-reboot-source FAIL "(the pattern video on the Roku and the card)"; return; }
	# shellcheck disable=SC2086
	ecp key --gap 1.5 $GC573_ROKU_REBOOT_KEYS
	lb=$(roku_loss_back 60 180)
	for i in $(seq 120); do ecp info > /dev/null 2>&1 && break; sleep 1; done
	sleep 10
	roku_play
	sleep 8
	check roku-reboot "$([ "${lb#* }" != - ] && [ "$(roku_counters)" -gt 30 ]; echo $?)" \
		"(input lost ${lb% *} s after the keys, back at ${lb#* } s; $(roku_timings); the pattern on the card again: $(roku_counters) of 60 counters read in 1 s)"
}

# the card's EDID (default.bin) and its variants (720p.bin, serial.bin) in DIR
roku_edids() {
	vm "mkdir -p $1 && v4l2-ctl -d $vdev --get-edid=format=raw,file=$1/default.bin" > /dev/null &&
		python3 "$ROOT/tools/roku/edid-variant.py" "$1/default.bin" "$1/serial.bin" --serial 0x5731 &&
		python3 "$ROOT/tools/roku/edid-variant.py" "$1/default.bin" "$1/720p.bin" --only-720p
}
roku_edid_set() { vm "v4l2-ctl -d $vdev --set-edid=file=$1,format=raw" > /dev/null; }
# an EDID set and the lock after it: first the hot-plug's loss (none within
# 10 s when the card had that EDID already), then the lock (60 s). Without
# the wait for the loss, time_to_lock returns at once on the lock before
# it. The 10 min soak's last capture (20261126-214248) started 2 s after
# its EDID set, between the loss and the new lock, which the delivery
# settle puts about 1 s later than before: no DV timings, and gc573-aud
# did not start
roku_edid_relock() {
	roku_edid_set "$1"
	wait_unlocked
	time_to_lock 60 > /dev/null
}

# rokuwhich: is the saved Roku the one cabled to the card? Passive: the
# card's EDID set to 720p only. If our EDID reaches the saved Roku, its
# device-info ui-resolution follows to 720p, and back after the default
# EDID. Only the saved Roku is asked (ecp.py survey --saved: no SSDP),
# never another one on the LAN, and nothing is saved. Its ui-resolution
# not following within 45 s leaves it unconfirmed (SKIP): our EDID does
# not reach it (a filter's own EDID), or its display type is set by hand
step_rokuwhich() {
	local e before out back r0 t m
	e=$W/roku-edid
	before=$(ecp survey --saved 2>&1)
	echo "  before: $before"
	m=$(sed -n 's/^\([^ :]*\): .*/\1/p' <<< "$before" | head -1)
	r0=$(sed -n 's/.*ui-resolution \([^,]*\),.*/\1/p' <<< "$before" | head -1)
	roku_edids "$e" || { result roku-which FAIL "(G_EDID or edid-variant.py)"; return; }
	echo "  the card before: $(roku_card)"
	roku_edid_set "$e/720p.bin"
	out=$(ecp survey --saved --watch 45 --until ui-resolution=720p 2>&1)
	sed 's/^/  720p only: /' <<< "$out"
	t=$(time_to_lock 20)
	echo "  the card with the 720p-only EDID: $(roku_card) (locked after $t ms)"
	roku_edid_set "$e/default.bin"
	back=""
	if grep -q '^MATCH' <<< "$out"; then
		back=$(ecp survey --saved --watch 45 --until "ui-resolution=${r0:-1080p}" 2>&1)
		sed 's/^/  default again: /' <<< "$back"
	fi
	t=$(time_to_lock 30)
	echo "  the card with the default EDID again: $(roku_card) (locked after $t ms)"
	vm "rm -rf $e"
	if grep -q '^MATCH' <<< "$out" && grep -q '^MATCH' <<< "$back"; then
		result roku-which PASS "(the saved Roku, the ${m:-?}, is the one cabled to the card: its ui-resolution followed the 720p-only EDID to 720p and back to ${r0:-1080p})"
	elif grep -q '^MATCH' <<< "$out"; then
		check roku-which 1 "(the saved ${m:-Roku} went to 720p with the 720p-only EDID, but not back to ${r0:-?} within 45 s of the default EDID)"
	else
		result roku-which SKIP "(the saved ${m:-Roku}'s ui-resolution did not follow the 720p-only EDID within 45 s: not confirmed; our EDID does not reach it, or its display type is set by hand)"
	fi
}

# the mean luma difference of two YUYV frames, in codes
frame_luma_diff() {
	python3 - "$1" "$2" <<'PY'
import sys
import numpy as np
a, b = (np.frombuffer(open(f, 'rb').read(), np.uint8)[0::2].astype(np.int16) for f in sys.argv[1:3])
n = min(len(a), len(b))
print(f'{float(np.abs(a[:n] - b[:n]).mean()):.2f}' if n else 'none')
PY
}

# rokuwhichkey (the go): rokuwhich's fallback. One Info key on the Roku
# that is on (power mode PowerOn), then Back. If the card's picture
# changes with the key, that Roku is the cabled one, and its address is
# saved as identified. Measured from the captured luma only (numbers, no
# picture kept): two frames 1 s apart before the key (how much the
# picture moves by itself, a screensaver), one 2 s after it
step_rokuwhichkey() {
	local out m d0 d1 f i
	roku_go || { roku_skip roku-which-key "sends Info and Back to the Roku that is on"; return; }
	out=$(ecp survey 2>&1)
	sed 's/^/  /' <<< "$out"
	m=$(grep -E '^[^ :]+: .*, PowerOn, ' <<< "$out" | cut -d: -f1)
	[ -n "$m" ] && [ "$(grep -c . <<< "$m")" = 1 ] ||
		{ result roku-which-key SKIP "(not exactly one Roku in PowerOn: $(paste -sd, - <<< "${m:-none}" | sed 's/,/, /g'))"; return; }
	locked || { result roku-which-key SKIP "(the card has no input: $(roku_reported); with the $m the one that is on, the cabled Roku sends nothing)"; return; }
	f=$W/which
	for i in a b; do
		vm "sudo $W/gc573-cap -d $vdev -L 5 -f YUYV -n 3 -o $f-$i > /dev/null 2>&1"
		sleep 1
	done
	ecp --model "$m" key Info
	sleep 2
	vm "sudo $W/gc573-cap -d $vdev -L 5 -f YUYV -n 3 -o $f-c > /dev/null 2>&1"
	ecp --model "$m" key Back
	d0=$(frame_luma_diff "$f-a.YUYV" "$f-b.YUYV")
	d1=$(frame_luma_diff "$f-b.YUYV" "$f-c.YUYV")
	vm "rm -f $f-*"
	if awk -v a="$d0" -v b="$d1" 'BEGIN { exit !(b + 0 > 3 * a && b + 0 > a + 4) }'; then
		ecp discover --save --model "$m" --identified info-key 2>&1 | tail -1 | sed 's/^/  /'
		check roku-which-key "${PIPESTATUS[0]}" "(the card's picture changed with Info on the $m: mean luma difference $d1 codes, against $d0 in 1 s without a key; that Roku is the cabled one)"
	else
		result roku-which-key SKIP "(no clear change with Info on the $m: $d1 codes, against $d0 in 1 s without a key; the cabled Roku is probably the other one)"
	fi
}

# rokumodes: EDID re-sets, each a hot-plug the Roku answers with a mode
# set: 720p only, the default with another serial number, the default
# again. Any picture, and nothing sent to the Roku but device-info queries
# of the saved one. Each: the lock, what the card sees 20 s on (the Roku
# may lock in its old mode first, then change), the kernel log's locks,
# the Roku's ui-resolution; the driver's own numbers in 10 s of gc573-aud
# -V (roku_drv). A Roku that does not follow the 720p-only EDID is INFO
# (its display type may be set by hand); the driver's part is the lock in
# whatever the Roku sends and a clean capture of it
step_rokumodes() {
	local e name t t2 i c
	e=$W/roku-edid
	time_to_lock 30 > /dev/null || { result roku-modes SKIP "(no input before the step: $(roku_card))"; return; }
	roku_edids "$e" || { result roku-modes FAIL "(G_EDID or edid-variant.py)"; return; }
	echo "  before: the Roku: $(ecp survey --saved 2>&1); the card: $(roku_card)"
	for name in 720p serial default; do
		kmsg_mark "rokumodes-$name"
		roku_edid_set "$e/$name.bin"
		sleep 2
		t=$(time_to_lock 60)
		for i in $(seq 20); do
			[ "$name" = 720p ] && roku_timings | grep -q 'Active width: 1280' && break
			sleep 1
		done
		t2=$(time_to_lock 30)
		c=$(roku_card)
		echo "  $name EDID: locked $t ms after the set; then: $c"
		echo "  the Roku: $(ecp survey --saved 2>&1); the kernel log's locks: $(lock_rates "$(kmsg_since "rokumodes-$name")")"
		[ "$name" != 720p ] || grep -q 'Active width: 1280' <<< "$c" ||
			echo "  INFO roku-edid-720p the Roku did not follow the 720p-only EDID within 20 s: $(roku_timings)"
		check "roku-edid-$name-lock" "$([ "$t" != none ] && [ "$t2" != none ]; echo $?)" \
			"(locked $t ms after the EDID set; locked 20 s on at $(roku_timings), $(roku_rate) Hz)"
		roku_drv "roku-edid-$name" "$ROKU_DRV_SECS"
		for i in $(seq 2 "$ROKU_DRV_REPS"); do
			sleep 2
			roku_drv "roku-edid-$name-$i" "$ROKU_DRV_SECS"
		done
	done
	vm "rm -rf $e"
}

# rokuobsany: OBS (the user's, started minimized, its sources checked) on
# whatever the Roku shows, passive: 10 screenshots 1 s apart (their size,
# luma, how much each differs from the one before), 20 s of the level
# meters, a 60 s recording (OBS's frame counters over it, the recording's
# length and frames; then deleted), and the driver's own numbers while
# OBS reads it: its stream delivering, its last 32 frame intervals, its
# error counters. Without our pattern there is no counter to follow and no
# A/V offset to measure
step_rokuobsany() {
	local out f r st0 st1 err rs
	time_to_lock 30 > /dev/null || { result roku-obsany SKIP "(no input: $(roku_card))"; return; }
	mkdir -p "$REC_DIR" || { result roku-obsany-recdir FAIL "(cannot make $REC_DIR)"; return; }
	obs_up || { result roku-obsany-start FAIL "(OBS minimized, with the sources expected)"; obs_down; return; }
	sleep 5
	st0=$(vid_stats)
	check roku-obsany-stream "$(vid_moving; echo $?)" "(the driver's stream with OBS reading it: frames delivered over 2 s; $(roku_card))"
	av_results roku-obsany "$(obsany shots 10 2>&1)"
	av_results roku-obsany "$(obsany meters 20 2>&1)"
	out=$(obsany record-start --dir "$REC_DIR" 2>&1)
	if grep -q '^STARTED' <<< "$out"; then
		sleep 60
		r=$(roku_ring)
		out=$(obsany record-stop 2>&1)
		rs=$?
		f=$(sed -n 's/^RECORDING //p' <<< "$out")
		grep -v '^RECORDING' <<< "$out" | sed 's/^/  /'
		check roku-obsany-record "$([ "$rs" = 0 ] && [ -n "$f" ] && [ -s "$f" ]; echo $?)" \
			"(record-stop exit $rs; $(grep -E '^(STATS|INFO)' <<< "$out" | paste -sd';' -))"
		[ -z "$f" ] || rm -f "$f"
	else
		r=$(roku_ring)
		result roku-obsany-record FAIL "(record-start: $(tr '\n' ' ' <<< "$out"))"
	fi
	check roku-obsany-intervals "$(roku_ring_ok "$r"; echo $?)" "(the driver's last frame interrupts while OBS read it: $r)"
	st1=$(vid_stats)
	err=$(vid_errors "$st0" "$st1")
	check roku-obsany-counters $? "(the driver's video counters: before $st0; after $st1${err:+; errors: $err})"
	echo "  OBS: $(obsany stats 2>&1)"
	obs_down
	rmdir "$REC_DIR" 2>/dev/null
}

# rokusoakany (the go): the 2-hour soak without playback, the Roku's own
# picture (its home screen, its animated screen saver). GC573_OBSSOAK_SECS
# (7200) with the user's OBS (minimized, its sources checked) recording to
# GC573_REC_DIR (deleted after the analysis), a change every
# GC573_OBSSOAK_EVERY s (180) from GC573_ROKUSOAK_ROTATION:
#   sleep         PowerOff, 20 s, Home (a PowerOff the Roku refuses leaves
#                 sleep out of the rest of the soak)
#   edid-same     the default EDID set again (a hot-plug)
#   edid-new      the default with another serial number (a new display)
#   edid-default  the default again
#   idle          nothing
#   reopen-video  OBS closes and opens the V4L2 device
#   reopen-audio  the same for the ALSA device
# Before and after each change (after: once the input has locked, within
# 60 s): the driver's stream delivering to OBS (else OBS's source reopened:
# a recovery; one needed without a lock in other timings, by the driver's
# stream policy, fails), its last 32 frame intervals, and OBS's picture (3
# screenshots 2 s apart: does it move? INFO). A sample a minute
# (host_sample): memory, CPU, the driver's counters (soak_samples). The
# driver's own numbers in 60 s of gc573-aud -V before OBS starts and after
# it stops; its buffer memory all given back after OBS. OBS's own frame
# counters over the recording and its log. The Roku stopping to answer ECP
# ends the soak (no retry)
ROKUSOAK_ROTATION=${GC573_ROKUSOAK_ROTATION:-sleep,edid-same,edid-new,idle,reopen-video,edid-default,reopen-audio}
sk_n=0 sk_e="" sk_base="" sk_sleep_off=0 sk_points=0 sk_ring_bad=0 sk_meds="" sk_lock_fail=0 sk_nosig=0
sk_stops=0 sk_stop_fail=0 sk_unrecovered=0 sk_moved=0 sk_still=0 sk_shot_fail=0
# a check point (LABEL): the input, the stream, its intervals, OBS's picture
soak_point() {
	local t c r sh mv keys
	t=$(time_to_lock 60)
	c=$(roku_card)
	sk_points=$((sk_points + 1))
	if [ "$t" = none ]; then
		if grep -q 'signal 1' <<< "$c"; then
			sk_lock_fail=$((sk_lock_fail + 1))
			echo "  POINT $1: no lock within 60 s with a signal: $c"
		else
			sk_nosig=$((sk_nosig + 1))
			echo "  POINT $1: INFO no signal from the Roku within 60 s: $c"
		fi
		return
	fi
	sleep 3
	if ! vid_moving; then
		sk_stops=$((sk_stops + 1))
		# a lock in other timings since the change can end the stream by the
		# driver's policy (a hold of 1 s); none, and the driver ended it
		keys=$(kmsg_since "rokusoak-change-$sk_n-" | grep -oE 'HDMI: locked: [0-9]+x[0-9]+[pi], [0-9]+ Hz' | sort -u | paste -sd';' -)
		if [ -z "$keys" ] || [ "$keys" = "$sk_base" ]; then
			sk_stop_fail=$((sk_stop_fail + 1))
			echo "  POINT $1: the driver's stream is not delivering, with no lock in other timings since the change (locks: ${keys:-none}): OBS's source reopened"
		else
			echo "  POINT $1: INFO the driver's stream is not delivering after a lock in other timings ($keys): OBS's source reopened"
		fi
		obsany reopen-video > /dev/null 2>&1
		sleep 5
		vid_moving || { sk_unrecovered=$((sk_unrecovered + 1)); echo "  POINT $1: not delivering after the reopen either"; }
	fi
	r=$(roku_ring)
	roku_ring_ok "$r" || sk_ring_bad=$((sk_ring_bad + 1))
	sk_meds+=" $(sed -n 's/.*median \([0-9.]*\) ms.*/\1/p' <<< "$r")"
	sh=$(obsany shots 3 --every 2 2>&1)
	grep -q '^RESULT any-shots PASS' <<< "$sh" || sk_shot_fail=$((sk_shot_fail + 1))
	mv=$(sed -n 's/.*; \([0-9]*\) of [0-9]* differ from.*/\1/p' <<< "$sh")
	if [ "${mv:-0}" -gt 0 ]; then sk_moved=$((sk_moved + 1)); else sk_still=$((sk_still + 1)); fi
	echo "  POINT $1: locked ($t ms) $c; ring $r; OBS ${sh#RESULT any-shots }"
}
# a change (KIND); 1 when the Roku has stopped answering ECP (the soak ends)
soak_change() {
	local i lost=held
	kmsg_mark "rokusoak-change-$sk_n-"
	case $1 in
	sleep)
		[ "$sk_sleep_off" = 0 ] || { echo "  CHANGE $sk_n sleep: left out (PowerOff refused or ignored earlier)"; return 0; }
		roku_key PowerOff
		case $? in
		1) sk_sleep_off=1; echo "  CHANGE $sk_n sleep: INFO PowerOff refused ($roku_err): no sleep in the rest of the soak"; return 0 ;;
		2) echo "  CHANGE $sk_n sleep: PowerOff: $roku_err"; return 1 ;;
		esac
		for i in $(seq 40); do
			locked || { lost="lost after $((i / 2)) s"; break; }
			sleep 0.5
		done
		sleep $((i < 40 ? 20 - i / 2 : 0))
		roku_power
		if [ "$lost" = held ] && [ "$roku_pm" = PowerOn ]; then
			rm -f "$ROKU_RUN/asleep"
			sk_sleep_off=1
			echo "  CHANGE $sk_n sleep: INFO not exercised: the signal held 20 s after PowerOff and the Roku reports PowerOn (it ignores ECP PowerOff); no Home, no sleep in the rest of the soak"
			return 0
		fi
		roku_key Home || { echo "  CHANGE $sk_n sleep: PowerOff, input $lost, power mode $roku_pm; Home: $roku_err"; return 1; }
		echo "  CHANGE $sk_n sleep: PowerOff, input $lost, power mode $roku_pm after 20 s; Home" ;;
	edid-same|edid-default|edid-new)
		roku_edid_set "$sk_e/$([ "$1" = edid-new ] && echo serial || echo default).bin"
		# the point after waits for the lock: first let the hot-plug's loss come
		if wait_unlocked; then lost="lost"; else lost="held 10 s"; fi
		echo "  CHANGE $sk_n $1: the input $lost" ;;
	idle) echo "  CHANGE $sk_n idle" ;;
	reopen-video) obsany reopen-video > /dev/null 2>&1; echo "  CHANGE $sk_n reopen-video" ;;
	reopen-audio) echo "  CHANGE $sk_n reopen-audio: $(obsany reopen-audio 2>&1 | tr '\n' ' ')" ;;
	*) echo "  CHANGE $sk_n $1: not a change of this soak" ;;
	esac
	return 0
}
step_rokusoakany() {
	local sp sampler m lg out f mem0 mem1 drv0 drv1 kinds kind t0 t_end now ended="" avail obs0 err rs
	roku_go || { roku_skip roku-soak "puts the Roku to sleep and wakes it during the soak"; return; }
	lib_kmsg_patterns	# for host_sample
	time_to_lock 30 > /dev/null || { result roku-soak SKIP "(no input: $(roku_card))"; return; }
	mkdir -p "$REC_DIR" || { result roku-soak-recdir FAIL "(cannot make $REC_DIR)"; return; }
	avail=$(df -k --output=avail "$REC_DIR" | tail -1)
	[ "$avail" -gt $((OBSSOAK_SECS * 6200 / 8 * 3)) ] ||
		{ result roku-soak-recdir FAIL "($REC_DIR: $((avail / 1024)) MB free)"; return; }
	sk_e=$W/roku-edid
	roku_edids "$sk_e" || { result roku-soak FAIL "(G_EDID or edid-variant.py)"; return; }
	sk_base=$(dmesg_locks_now)
	echo "  the card: $(roku_card); the lock: ${sk_base:-?}; rotation $ROKUSOAK_ROTATION"
	roku_drv roku-soak-driver-first 60
	mem0=$(mem_snapshot)
	drv0=$(drv_mem)
	obs_up || { result roku-soak-start FAIL "(OBS minimized, with the sources expected)"; obs_down; return; }
	m=$(obs_log_mark)
	sp=${log%.log}-rokusoak-samples.txt
	( while :; do host_sample; sleep 60; done ) > "$sp" 2>&1 &
	sampler=$!
	sleep 5
	out=$(obsany record-start --dir "$REC_DIR" 2>&1)
	check roku-soak-record-start "$(grep -q '^STARTED' <<< "$out"; echo $?)" "($(tr '\n' ' ' <<< "$out"))"
	obs0=$(obsany stats 2>&1)
	IFS=, read -ra kinds <<< "$ROKUSOAK_ROTATION"
	t0=$(date +%s)
	t_end=$((t0 + OBSSOAK_SECS))
	echo "  rokusoak: $OBSSOAK_SECS s from $(date -u '+%H:%M:%S UTC'), a change every $OBSSOAK_EVERY s"
	kmsg_mark "rokusoak-change-0-"
	soak_point "0 start"
	while [ "$(date +%s)" -lt "$t_end" ]; do
		kind=${kinds[sk_n % ${#kinds[@]}]}
		# before: the kernel log since the change before (its mark)
		soak_point "$((sk_n + 1)) before $kind"
		sk_n=$((sk_n + 1))
		soak_change "$kind" || { ended="the Roku stopped answering ECP at change $sk_n ($kind)"; break; }
		soak_point "$sk_n after $kind"
		now=$(date +%s)
		[ $((t0 + sk_n * OBSSOAK_EVERY)) -le "$now" ] || sleep $(( (t0 + sk_n * OBSSOAK_EVERY < t_end ? t0 + sk_n * OBSSOAK_EVERY : t_end) - now ))
	done
	soak_point "end"
	echo "  OBS at the start: $obs0"
	echo "  OBS at the end:   $(obsany stats 2>&1)"
	out=$(obsany record-stop 2>&1)
	rs=$?
	f=$(sed -n 's/^RECORDING //p' <<< "$out")
	grep -v '^RECORDING' <<< "$out" | sed 's/^/  /'
	check roku-soak-record "$([ "$rs" = 0 ] && [ -n "$f" ] && [ -s "$f" ]; echo $?)" \
		"(record-stop exit $rs; OBS over the recording: $(grep -E '^(STATS|INFO)' <<< "$out" | paste -sd';' -))"
	[ -z "$f" ] || rm -f "$f"
	host_sample >> "$sp" 2>&1
	kill "$sampler" 2>/dev/null
	wait "$sampler" 2>/dev/null
	obs_down
	lg=$(vm "tail -n +$((m + 1)) \"\$(ls -t ~/.config/obs-studio/logs/*.txt | head -1)\"")
	roku_edid_relock "$sk_e/default.bin"
	vm "rm -rf $sk_e"
	sleep 2
	roku_drv roku-soak-driver-last 60
	check roku-soak-length "$([ -z "$ended" ]; echo $?)" \
		"(${ended:-the whole $OBSSOAK_SECS s}: $sk_n changes; $(date -u '+%H:%M:%S UTC') now)"
	check roku-soak-lock "$([ "$sk_lock_fail" = 0 ]; echo $?)" \
		"($sk_points check points: $sk_lock_fail without a lock within 60 s while the Roku sent a signal; $sk_nosig without a signal from the Roku (INFO))"
	check roku-soak-stream "$([ "$sk_stop_fail" = 0 ] && [ "$sk_unrecovered" = 0 ]; echo $?)" \
		"(the driver's stream delivering to OBS at every point but $sk_stops: $sk_stop_fail of them with no lock in other timings, $sk_unrecovered not back after OBS's reopen)"
	check roku-soak-intervals "$([ "$sk_ring_bad" = 0 ]; echo $?)" \
		"(the driver's last 32 frame intervals at each point within half a period of their median: $sk_ring_bad points not; medians $(tr ' ' '\n' <<< "$sk_meds" | grep . | sort -n | sed -n '1p;$p' | paste -sd'-' -) ms)"
	check roku-soak-obs-shots "$([ "$sk_shot_fail" = 0 ]; echo $?)" \
		"(OBS's screenshots at every point: $sk_shot_fail points with one failed or of another size)"
	if [ "$sk_moved" = 0 ]; then
		echo "  INFO roku-soak-picture OBS-side freeze detection was not possible: OBS's picture stood still between screenshots 2 s apart at all $sk_still points (a still screen: a freeze would look the same). Freezes are judged by the driver's numbers alone (roku-soak-stream: frames delivered to OBS at every point)"
	else
		echo "  INFO roku-soak-picture OBS's picture moved between screenshots 2 s apart at $sk_moved points (the screen saver animating: OBS not frozen there) and stood still at $sk_still (a still screen or a freeze: not told apart; the driver's frames moved at every point unless roku-soak-stream says otherwise)"
	fi
	echo "  obs: $(grep -c 'select timed out' <<< "$lg") select timeouts, $(grep -c 'failed to dequeue' <<< "$lg") dequeue failures, $(grep -c 'Start capture' <<< "$lg") device opens"
	grep -E 'skipped frames|lagged frames|Total (frames output|drawn frames)|Recording (Start|Stop)' <<< "$lg" |
		sed 's/^/  obs log: /' | head -12
	rmdir "$REC_DIR" 2>/dev/null
	sync
	sleep 10
	mem1=$(mem_snapshot)
	drv1=$(drv_mem)
	out=$(join <(sort <<< "$mem0") <(sort <<< "$mem1") | awk '
		$1 == "SUnreclaim" { a = $2; b = $3; next }
		$1 ~ /^kmalloc-([0-9]+k?|rnd-[0-9]+-[0-9]+k?)$/ { k0 += $2; k1 += $3 }
		END { printf "INFO memory-kmalloc live objects in the kmalloc caches: %d kB before OBS started, %d kB after OBS exited and the recording was deleted, %+d kB (every program'"'"'s); SUnreclaim %d -> %d kB (%+d)\n", k0, k1, k1 - k0, a, b, b - a }')
	av_results roku-soak "$out"
	if [ -z "$drv0" ] || [ -z "$drv1" ]; then
		result roku-soak-memory SKIP "(the loaded gc573 has no live-memory line in debugfs video)"
	else
		check roku-soak-memory "$([ "$drv1" = "$DRV_MEM_ZERO" ] && [ "$drv0" = "$DRV_MEM_ZERO" ]; echo $?)" \
			"(the driver's own buffer memory, debugfs video \"mem\": before OBS $drv0; after OBS exited $drv1)"
	fi
	av_results roku-soak "$(soak_samples "$sp")"
}
# the lock now, as the kernel log's last lock line has it (size, clock)
dmesg_locks_now() { vm "sudo dmesg" | grep -oE 'HDMI: locked: [0-9]+x[0-9]+[pi], [0-9]+ Hz' | tail -1; }
# host_sample's lines (FILE): memory and CPU over the soak, and the
# driver's counters, each summed over the samples (a counter that goes
# down started again with a new stream). RESULT driver-counters fails on
# the error counters
soak_samples() {
	awk 'NR == 1 || NR % 10 == 0 { print "mem: " $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13 }' "$1"
	awk -v hz="$(getconf CLK_TCK)" '
		$14 == "|" { n++; t[n] = $1; avail[n] = $2; slab[n] = $3; sunr[n] = $4; vm[n] = $5; rss[n] = $7
			obs[n] = $8; irq[n] = $9; split($10, c, ":"); busy[n] = c[1]; idle[n] = c[2]
			for (i = 15; i <= NF; i++) { split($i, kv, "="); k = kv[1]; x = kv[2] + 0; names[k] = 1
				if (k in last) { d = x - last[k]; if (d < 0) d = x; tot[k] += d }
				last[k] = x }
			kall = $11; kdrv = $12; kbad = $13 }
		END {
			if (n < 7) { print "INFO memory: " n " samples, fewer than 7"; exit }
			s = 6
			printf "INFO memory from minute 5 to the end: SUnreclaim %+d kB (the recording'"'"'s page cache counts), Slab %+d kB, VmallocUsed %+d kB, MemAvailable %+d kB, OBS RSS %+d kB\n",
				sunr[n] - sunr[s], slab[n] - slab[s], vm[n] - vm[s], avail[n] - avail[s], rss[n] - rss[s]
			wall = t[n] - t[1]
			printf "RESULT cpu PASS (report only: OBS %.1f %% of one CPU, the IRQ thread %.2f %%, the host %.1f %% of its CPUs, over %d s)\n",
				(obs[n] - obs[1]) / hz / wall * 100, (irq[n] - irq[1]) / hz / wall * 100,
				(busy[n] - busy[1]) / ((busy[n] - busy[1]) + (idle[n] - idle[1])) * 100, wall
			split("v_bad_status v_unarmed v_order a_bad_done a_order h_poll_errors h_xfer_errors", errs, " ")
			for (i in errs) iserr[errs[i]] = 1
			for (k in names) {
				if (k ~ /^(v_(frames|skipped|multi|stale|terms|term_missing|underruns|input_restarts|input_stops|input_holds|bad_status|unarmed|order)|a_(periods|silent|pauses|starts|restarts|stops|stop_missing|stale|late|bad_done|order)|h_(failed|poll_errors|xfer_errors|retries|resyncs|runs|fpga_rejects|fpga_heals)|it_(entries|losses|releases)|sp_(link_errors|level_changes|repowers|failed|pll_recoveries|scdc_aborts))$/ && tot[k])
					info = info sprintf(" %s +%d", k, tot[k])
				if (k in iserr && tot[k]) bad = bad sprintf(" %s +%d", k, tot[k])
			}
			printf "RESULT driver-counters %s (over the soak, %d samples:%s%s; kernel log: %d lines, %d of the driver, %d bad)\n",
				bad == "" ? "PASS" : "FAIL", n, info == "" ? " no counter moved" : info,
				bad == "" ? "" : "; errors:" bad, kall, kdrv, kbad
		}' "$1"
}

# rokustart: streams started at a fresh lock (the 720p stream's phase step,
# 20261126-183914). GC573_ROKU_TRIALS (6) times: the default EDID, the lock,
# 5 s; then the 720p-only EDID and at once gc573-cap -L 10 (it starts at the
# lock, as the loopback's change step restarts; GC573_ROKU_START_DELAY s
# after it instead): 120 YUYV frames with
# every buffer pattern-filled before its QBUF (-p: blocks the DMA did not
# write), per-frame signatures of 18 bands top to bottom (-B), and the
# driver's frame-interrupt ring read every 0.3 s, and after each DQBUF the
# FPGA's input block read through BAR0 (-M, sysfs resource0 mapped read-only,
# as tests/exp-delivery.sh does): IN_FRAME_PERIOD (0x1010), the period of
# the input as the FPGA measures it, says whether the source's frames were
# regular across a step or not. Meanwhile tests/dbg-watch.py reads debugfs
# hdmi every 25 ms: the HDMI poll worker's polls, I2C transfers and
# sequence runs, the IT6805's and the splitter's states, with their
# CLOCK_MONOTONIC times, so that a step lines up with the worker's work
# or not. Then the same at 1080p
# (the default EDID set again). GC573_ROKU_START_FIRST=serial: the EDID
# with another serial number instead of the 720p one, a hot-plug the Roku
# answers in the same mode (streams started at a lock in the same timings;
# tags serial-N and serial-back-N). A stream passes (hdmi-chips.md "Lock policy",
# delivery settle) when every frame interval is within 10 % of
# IN_FRAME_PERIOD and its first 40 intervals' mean within 0.05 % of it:
# the input's frames from the first frame after the published lock, not
# the card's own 60.000 Hz. Per stream, for each interval more than 10 %
# off, the phase of the frames around
# it, their untouched bytes, which bands of the off frame match the frame
# before (<), the frame after (>), both (=) or neither (x), and the ring of
# that time. No Roku action but the EDID sets; numbers only
roku_start_one() {	# TAG EDIDFILE [DELAY: s from the lock to the stream]
	local rp wp out
	roku_edid_set "$2"
	if [ "${3:-0}" -gt 0 ]; then
		time_to_lock 60 > /dev/null
		sleep "$3"
	fi
	vm "sudo python3 $ROOT/tests/dbg-watch.py --secs 7 --every 25 '$dbgdir/hdmi=^(hdmi: polling|it6805: state|splitter: (rx|tx1|eq))'" \
		> "$W/start-watch.txt" 2>&1 &
	wp=$!
	( while :; do
		vm "sudo cat $dbgdir/video" | awk '/^events/ { f = 1; next } f && $1 ~ /^[0-9]+$/'
		sleep 0.3
	done ) > "$W/start-ring.txt" 2> /dev/null &
	rp=$!
	vm "sudo $W/gc573-cap -d $vdev -L 10 -f YUYV -b 4 -n 120 -p -F -B -M /sys/bus/pci/devices/${dbgdir##*/gc573-}/resource0 > $W/start.txt 2>&1"
	kill "$rp" 2> /dev/null
	wait "$rp" 2> /dev/null
	wait "$wp"
	sort -u "$W/start-ring.txt" > "$W/start-ring.u"
	# ring times are CLOCK_MONOTONIC ns, the frame lines' ts_ms the same in ms
	out=$(awk -v tag="$1" 'FILENAME == ARGV[1] { nr++; rt[nr] = $1 / 1e6; r[nr] = $0; next }
		FILENAME == ARGV[2] { if ($1 == "W") { nw++; wt[nw] = $2 / 1e6; wl[nw] = $0 }; next }
		/^LOCK / { lk = $0 }
		# REGS: 0x300-0x3fc, then 0x1000-0x10fc; 0x1010 is word 68 ($71)
		/^REGS / { split($2, rq, "="); per[rq[2]] = strtonum("0x" $71); cst[rq[2]] = $3 }
		/^FRAME / { n++
			for (i = 2; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
			seq[n] = v["seq"]; ts[n] = v["ts_ms"]; un[n] = v["untouched"]; nb = split(v["bands"], b, ",")
			for (k = 1; k <= nb; k++) bd[n, k] = b[k]
			if (v["untouched"] > 0) nun++
			p = per[v["seq"]]; fp[n] = p
			if (p) { if (!pmin || p < pmin) pmin = p; if (p > pmax) pmax = p } }
		END {
			if (n < 3) { printf "RESULT %s FAIL (%d frames: %s)\n", tag, n, lk; exit }
			for (i = 2; i <= n; i++) { d[i] = ts[i] - ts[i - 1]; x[i - 1] = d[i] }
			m = n - 1
			for (i = 2; i <= m; i++) { t = x[i]; for (j = i - 1; j >= 1 && x[j] > t; j--) x[j + 1] = x[j]; x[j + 1] = t }
			med = x[int((m + 1) / 2)]
			# the reference: the input period the FPGA measures (else the median)
			ref = pmin ? pmin / 1e5 : med
			for (i = 2; i <= n; i++) if (d[i] > ref * 1.1 || d[i] < ref * 0.9) {
				off++
				printf "  %s interval off: frame %d of %d (%.3f s in), seq %d -> %d, %.3f ms (input period %.3f, median %.3f)\n", tag, i, n, (ts[i] - ts[1]) / 1e3, seq[i - 1], seq[i], d[i], ref, med
				ph = ""
				for (k = i - 2; k <= i + 1; k++) ph = ph (k >= 1 && k <= n ? sprintf(" %+.3f", ts[k] - ts[1] - (k - 1) * med) : " -")
				printf "    phase against the median cadence, frames %d to %d:%s ms; untouched 32-byte blocks%s\n", i - 2, i + 1, ph,
					sprintf(" %s %s %s %s", un[i - 2], un[i - 1], un[i], un[i + 1])
				bs = ""
				for (k = 1; k <= nb; k++) {
					p = (i > 1 && bd[i, k] == bd[i - 1, k]); q = (i < n && bd[i, k] == bd[i + 1, k])
					bs = bs (p && q ? "=" : p ? "<" : q ? ">" : "x")
				}
				printf "    frame %d by band, top to bottom (< as the frame before, > as the one after, = both, x neither): %s\n", i, bs
				printf "    IN_FRAME_PERIOD (100 MHz ticks) read after frames %d to %d: %s %s %s %s\n", i - 2, i + 1, fp[i - 2], fp[i - 1], fp[i], fp[i + 1]
				for (j = 1; j <= nw; j++) if (wt[j] >= ts[i - 1] - 400 && wt[j] <= ts[i] + 100) {
					line = wl[j]; sub(/^W [0-9]+ /, "", line)
					if (line ~ /^hdmi hdmi: polling/) {
						cn = ""; n2 = split(line, f, " ")
						for (q2 = 1; q2 < n2; q2++) if (f[q2] ~ /^(polls|xfers|runs|lock_polls|retries|resyncs|poll_errors)$/) cn = cn " " f[q2] " " f[q2 + 1]
						line = "hdmi:" cn
					}
					printf "    watch: %+.1f ms from frame %d: %s\n", wt[j] - ts[i - 1], i - 1, line
				}
				for (j = 1; j <= nr; j++) if (rt[j] >= ts[i > 3 ? i - 3 : 1] - 1 && rt[j] <= ts[i + 2 <= n ? i + 2 : n] + 1) {
					split(r[j], e, " ")
					printf "    ring: %+.3f ms from frame %d, status %s ctrl %s done %s armed %s\n", rt[j] - ts[i - 1], i - 1, e[2], e[3], e[4], e[5]
				}
			}
			printf "  %s IN_FRAME_PERIOD over the stream: %d to %d ticks (%.4f to %.4f ms)\n", tag, pmin, pmax, pmin / 1e5, pmax / 1e5
			# the delivery rate before and after: the first and last 40 intervals
			slow = 0
			if (n > 81) {
				a1 = (ts[41] - ts[1]) / 40; a2 = (ts[n] - ts[n - 40]) / 40
				printf "  %s mean interval of the first 40: %.4f ms (%.3f Hz); of the last 40: %.4f ms (%.3f Hz)\n", tag, a1, 1000 / a1, a2, 1000 / a2
				slow = a1 < ref * 0.9995 || a1 > ref * 1.0005
			}
			printf "RESULT %s %s (%d frames, input period %.4f ms, %d intervals more than 10 %% off it, the first 40 %s; %d frames with 32-byte blocks the DMA did not write; %s)\n",
				tag, (off || nun || slow) ? "FAIL" : "PASS", n, ref, off,
				(n > 81 ? sprintf("at %.4f ms (%s 0.05 %%)", a1, slow ? "not within" : "within") : "not measured"), nun, lk }' "$W/start-ring.u" "$W/start-watch.txt" "$W/start.txt")
	av_results roku-start "$(sed 's/^RESULT /RESULT /' <<< "$out")"
	grep -E '^(INFO start_to_first|RESULT capture)' "$W/start.txt" | sed 's/ ch0_bytes.*//; s/^/  /'
	grep -v '^W ' "$W/start-watch.txt" | head -3 | sed 's/^/  dbg-watch: /'
	vm "rm -f $W/start.txt $W/start-ring.txt $W/start-ring.u $W/start-watch.txt"
}
step_rokustart() {
	local e i a=${GC573_ROKU_START_FIRST:-720p} b
	b=$([ "$a" = 720p ] && echo 1080p || echo "$a-back")
	e=$W/roku-edid
	time_to_lock 30 > /dev/null || { result roku-start SKIP "(no input: $(roku_card))"; return; }
	roku_edids "$e" || { result roku-start FAIL "(G_EDID or edid-variant.py)"; return; }
	for i in $(seq "${GC573_ROKU_TRIALS:-6}"); do
		roku_edid_set "$e/default.bin"
		time_to_lock 60 > /dev/null
		sleep 5
		roku_start_one "$a-$i" "$e/$a.bin" "${GC573_ROKU_START_DELAY:-0}"
		sleep 5
		roku_start_one "$b-$i" "$e/default.bin" "${GC573_ROKU_START_DELAY:-0}"
		sleep 2
	done
	roku_edid_relock "$e/default.bin"
	vm "rm -rf $e"
}

# rokurelock: a stream across a relock in the same timings, the restart the
# stream policy makes (hdmi-chips.md "Stream policy on input changes").
# GC573_ROKU_TRIALS (3) times: gc573-cap -L (720 YUYV frames, -p -F -M) on
# the locked input; 3 s in, an EDID with another serial number (then the
# default again, in turn): a new display, which the Roku answers with a
# loss and the same mode (the same EDID set again brings no loss: the soak
# 20261126-190906). The driver restarts the stream free-running at
# the loss and live at the relock; tests/dbg-watch.py reads debugfs video's
# "stream:" line every 25 ms for the time of the live restart, and hdmi's
# input and IT6805 lines for the loss, the stable entry and the published
# lock (an INFO timeline from the stable entry, with the longest interval
# and each change of the FPGA's status and frame period, 0x1004 and 0x1010,
# as the frames' register reads saw them; and the free-run frames from the
# stable entry to the live restart, with the input there but no lock
# published: their intervals against 60 Hz, where a re-phase would show).
# From 0.1 s after the live restart to the end every interval within 10 %
# of IN_FRAME_PERIOD, and the first 40 within 0.05 % of it on average (the
# delivery settle). Numbers only; no Roku action but the EDID set
step_rokurelock() {
	local e i wp cp out
	e=$W/roku-edid
	time_to_lock 30 > /dev/null || { result roku-relock SKIP "(no input: $(roku_card))"; return; }
	roku_edids "$e" || { result roku-relock FAIL "(G_EDID or edid-variant.py)"; return; }
	for i in $(seq "${GC573_ROKU_TRIALS:-3}"); do
		vm "sudo python3 $ROOT/tests/dbg-watch.py --secs 15 --every 25 '$dbgdir/video=^stream:' '$dbgdir/hdmi=^(it6805: state|input:)'" \
			> "$W/relock-watch.txt" 2>&1 &
		wp=$!
		vm "sudo $W/gc573-cap -d $vdev -L 10 -f YUYV -b 4 -n 720 -p -F -M /sys/bus/pci/devices/${dbgdir##*/gc573-}/resource0 > $W/relock.txt 2>&1" &
		cp=$!
		sleep 3
		kmsg_mark "rokurelock-$i-"
		roku_edid_set "$e/$([ $((i % 2)) = 1 ] && echo serial || echo default).bin"
		wait "$cp"
		wait "$wp"
		out=$(awk -v tag="$i" 'FILENAME == ARGV[1] {
				if ($1 != "W") next
				t = $2 / 1e6
				if ($3 == "video") {
					if ($0 !~ / live 1 /) { was0 = 1; if (!tf) tf = t }
					else if (was0 && !tl) tl = t
				} else if ($4 == "input:") {
					if ($0 ~ / locked 0 /) { if (!tlo) tlo = t }
					else if (tlo && !tp) tp = t
				} else if ($4 == "it6805:" && match($0, / entries [0-9]+/)) {
					en = substr($0, RSTART + 9, RLENGTH - 9) + 0
					if (ens && en > en0 && !tp) te = t
					en0 = en; ens = 1
				}
				next }
			/^REGS / { split($2, rq, "="); per[rq[2]] = strtonum("0x" $71); fst[rq[2]] = $68 "/" $71 }
			/^FRAME / { for (k = 2; k <= NF; k++) { split($k, kv, "="); v[kv[1]] = kv[2] }
				# the timeline: the longest interval, the first frame after the restart,
				# the FPGA status and period changes
				# (a period within 2 ticks of the last one listed is no change)
				split(fst[v["seq"]], sp, "/"); fpn = strtonum("0x" sp[2])
				if ((!nfc || sp[1] != fls || fpn > flp + 2 || fpn < flp - 2) && nfc < 8) {
					fc[++nfc] = v["ts_ms"]; fv[nfc] = fst[v["seq"]]; fls = sp[1]; flp = fpn }
				if (lt && v["ts_ms"] - lt > dmax) { dmax = v["ts_ms"] - lt; dend = v["ts_ms"] }
				# the free-run frames between the stable entry and the live restart
				if (te && lt && v["ts_ms"] > te && (!tl || v["ts_ms"] < tl)) {
					d0 = v["ts_ms"] - lt; nfr++
					if (!fmin || d0 < fmin) fmin = d0
					if (d0 > fmax) fmax = d0
					if (d0 > 1000 / 60 * 1.1 || d0 < 1000 / 60 * 0.9) {
						froff++
						if (nfo < 4) fo = fo sprintf("%s%.1f ms ending at %+.0f ms", nfo++ ? ", " : "", d0, v["ts_ms"] - te)
					}
				}
				lt = v["ts_ms"]
				if (tl && !t1 && lt >= tl) t1 = lt
				if (!tl || v["ts_ms"] < tl + 100) next
				n++; ts[n] = v["ts_ms"]; seq[n] = v["seq"]; p = per[v["seq"]]
				if (p && (!pmin || p < pmin)) pmin = p
				if (v["untouched"] > 0) nun++ }
			END {
				b = te ? te : tl
				printf "  %s timeline from the %s: loss %s, free-run restart %s, published lock %s, live restart %s, its first frame %s; longest interval %.1f ms, ending at %s\n",
					tag, te ? "stable entry" : "live restart", rel(tlo, b), rel(tf, b), rel(tp, b), rel(tl, b), rel(t1, b), dmax, rel(dend, b)
				fs = ""
				for (k = 1; k <= nfc; k++) fs = fs sprintf("%s%s %s", k > 1 ? ", " : "", fv[k], rel(fc[k], b))
				printf "  %s FPGA status/frame period (0x1004/0x1010) from frame reads: %s\n", tag, fs
				if (nfr) printf "  %s free-run frames from the stable entry to the live restart: %d intervals, %.3f to %.3f ms, %d more than 10 %% off 16.667%s\n", tag, nfr, fmin, fmax, froff + 0, fo != "" ? " (" fo ")" : ""
				else printf "  %s free-run frames from the stable entry to the live restart: none\n", tag
				if (!tl) { printf "RESULT %s FAIL (no live restart seen in debugfs video)\n", tag; exit }
				if (n < 42) { printf "RESULT %s FAIL (%d frames after the live restart)\n", tag, n; exit }
				ref = pmin / 1e5
				for (k = 2; k <= n; k++) { d = ts[k] - ts[k - 1]
					if (d > ref * 1.1 || d < ref * 0.9) {
						off++
						printf "  %s interval off: frame %d after the restart (%.3f s after it), seq %d -> %d, %.3f ms (input period %.3f)\n", tag, k, (ts[k] - tl) / 1e3, seq[k - 1], seq[k], d, ref
					} }
				a1 = (ts[41] - ts[1]) / 40
				slow = a1 < ref * 0.9995 || a1 > ref * 1.0005
				printf "RESULT %s %s (%d frames from 0.1 s after the live restart, input period %.4f ms: %d intervals more than 10 %% off it, the first 40 at %.4f ms (%s 0.05 %%); %d frames with 32-byte blocks the DMA did not write)\n",
					tag, (off || slow || nun) ? "FAIL" : "PASS", n, ref, off, a1, slow ? "not within" : "within", nun }
			function rel(x, b) { return x ? sprintf("%+.0f ms", x - b) : "not seen" }' \
			"$W/relock-watch.txt" "$W/relock.txt")
		av_results roku-relock "$out"
		echo "  $(lock_rates "$(kmsg_since "rokurelock-$i-")"); $(grep -E '^RESULT capture' "$W/relock.txt" | sed 's/ ch0_bytes.*//')"
		vm "rm -f $W/relock.txt $W/relock-watch.txt"
		sleep 3
	done
	roku_edid_relock "$e/default.bin"
	vm "rm -rf $e"
}

# rokuobssoak: obssoak with the Roku: OBS records GC573_OBSSOAK_SECS while
# the Roku plays the pattern video, a change every GC573_OBSSOAK_EVERY s
# from GC573_OBSSOAK_ROTATION (default: the Roku's sleep, EDID re-sets,
# OBS's reopens). obssoak_local does the rest (recording, A/V offset,
# memory, OBS's log)
step_rokuobssoak() {
	roku_go || { roku_skip roku-obssoak "plays our pattern video on the Roku for the soak"; return; }
	roku_source_on $((OBSSOAK_SECS + 900)) ||
		{ result roku-obssoak-source FAIL "(the pattern video on the Roku and the card)"; return; }
	OBSSOAK_ROTATION=${GC573_OBSSOAK_ROTATION:-sleep,edid-same,edid-new,idle,reopen-video,edid-default,reopen-audio}
	export GC573_SOURCE=roku GC573_ROKU_URL_FILE=$ROKU_URL_FILE
	obssoak_local
}

# q25: open question 25, the Roku without the HDCP filter (the user moves
# the cable a second time). Over GC573_Q25_SECS (180): what the driver
# reports (the input line, QUERY_DV_TIMINGS), the kernel log's HDMI lines
# and the self-heal's attempts and counters. Then a capture of 120 YUYV
# frames (with -L when locked, else free-running), which must end within
# 70 s (q25-no-hang; a capture that does not is left running for the
# coordinator) and must not deliver noise (q25-no-garbage: its last frame
# uniform, such as the free-run black, or a picture, not noise; numbers
# only). With the go, whether the pattern video comes through (INFO: an
# HDCP receiver that decrypts would show it). The unbind with this input
# is the coordinator's: live.sh never unbinds on the host
roku_reported() {
	local q
	q=$(query)
	# after a failure v4l2-ctl prints the zeroed timings too
	if ! grep -q 'failed' <<< "$q" && grep -q 'Active width' <<< "$q"; then
		echo "QUERY_DV_TIMINGS $(grep -oE 'Active width: [0-9]+|Active height: [0-9]+|Pixelclock: [0-9]+ Hz' <<< "$q" | paste -sd, -)"
	else
		echo "QUERY_DV_TIMINGS $(grep -oE 'failed: .*' <<< "$q" | head -1)"
	fi
}
# the class of a YUYV frame (FILE WIDTH) from its luma: uniform, a picture
# (neighbours a few codes apart) or noise (tens of codes apart)
frame_class() {
	python3 - "$1" "$2" <<'PY'
import sys
import numpy as np
w = int(sys.argv[2])
y = np.frombuffer(open(sys.argv[1], 'rb').read(), np.uint8)[0::2].astype(np.int16)
y = y[:len(y) // w * w].reshape(-1, w)
lo, hi = int(y.min()), int(y.max())
step = float(np.abs(np.diff(y, axis=1)).mean())
kind = 'uniform' if hi - lo <= 8 else 'a picture' if step < 12 else 'noise'
print(f"RESULT no-garbage {'FAIL' if kind == 'noise' else 'PASS'} (the last frame: {kind}; "
      f"luma {lo}-{hi}, neighbours {step:.1f} codes apart on average)")
PY
}
step_q25() {
	local i st out log h0 h1 lk cpid w
	kmsg_mark q25
	h0=$(heal_counts)
	echo "  Roku: $(ecp info 2>&1)"
	for i in $(seq 6); do
		echo "  +$(((i - 1) * Q25_SECS / 6)) s: $(roku_input); $(roku_reported)"
		sleep $((Q25_SECS / 6))
	done
	lk=""
	! locked || lk="-L 10"
	vm "sudo $W/gc573-cap -d $vdev $lk -f YUYV -n 120 -o $W/q25 > $W/q25.txt 2>&1" &
	cpid=$!
	for i in $(seq 70); do
		kill -0 "$cpid" 2>/dev/null || break
		sleep 1
	done
	if kill -0 "$cpid" 2>/dev/null; then
		st=hung
	else
		wait "$cpid"
		st=$?
	fi
	check q25-no-hang "$([ "$st" != hung ]; echo $?)" \
		"(120 YUYV frames, $([ -n "$lk" ] && echo 'the timings set from QUERY_DV_TIMINGS' || echo 'not locked: free-running'): $([ "$st" = hung ] && echo 'not ended after 70 s, left running' || echo "exit $st"))"
	if [ "$st" != hung ]; then
		w=$(vm "v4l2-ctl -d $vdev --get-fmt-video" | sed -n 's/.*Width\/Height *: *\([0-9]*\)\/.*/\1/p')
		if [ -s "$W/q25.YUYV" ] && [ -n "$w" ]; then
			out=$(frame_class "$W/q25.YUYV" "$w")
		else
			out="RESULT no-garbage PASS (no frame delivered: $(grep -m1 -iE 'error|fail|lock|signal' "$W/q25.txt" 2>/dev/null | head -c 160))"
		fi
		av_results q25 "$out"
		vm "rm -f $W/q25.*"
	fi
	if roku_go; then
		roku_source_on 3600
		echo "  INFO the pattern video, played: $(roku_counters) of 60 counters read in 1 s; $(roku_input); $(roku_reported)"
	fi
	log=$(kmsg_since q25 | grep 'gc573')
	grep -E 'HDMI|HDCP' <<< "$log" | sed 's/^/  | /'
	h1=$(heal_counts)
	echo "  the self-heal with this input: $(grep -c 'HDMI: self-heal [0-9] of' <<< "$log") attempts, $(grep -c 'self-heal gave up' <<< "$log") give-ups; counters fpga_heals, fixes, giveups: ${h0:--} -> ${h1:--}"
	result q25-unbind SKIP "(the coordinator's: live.sh never unbinds on the host)"
}

# q25back: the filter back in the path (the user's cable move): the input
# locks again without a reload, and with the go the pattern plays
step_q25back() {
	local t
	t=$(time_to_lock 60)
	check q25-back-lock "$([ "$t" != none ]; echo $?)" "(locked $t ms into the step: $(roku_timings); $(roku_input))"
	roku_go || return 0
	roku_source_on 3600
	check q25-back-pattern "$([ "$(roku_counters)" -gt 30 ]; echo $?)" \
		"(the pattern on the card: $(roku_counters) of 60 counters read in 1 s)"
}

if [ "$SOURCE" = roku ]; then
	roku_refuse() {
		echo "live.sh: $1 drives $OUT, which GC573_SOURCE=roku never touches" >&2
		ev "refused (source roku): $1"
		return 1
	}
	src_on() { roku_refuse src_on; }
	src_off() { roku_refuse src_off; }
	av_on() { roku_refuse av_on; }
	colour_set() { roku_refuse colour_set; }
	colour_restore() { return 0; }
	ROKU_RUN=$(mktemp -d /tmp/gc573-roku-run.XXXXXX)
fi

# ---- main ----

all="bringup lock relock fpgawait fpgaheal capture modes change blip loss colour colorimetry audio exact avsync audioloss"
all+=" obs obsav obschange obsws obsevents avchange unload reload compliance"
[ "$LOCAL" = 0 ] || all="bringup lock relock capture modes change blip loss audio exact avsync audioloss compliance"
ROKU_STEPS="rokuwhich rokuwhichkey rokulock rokucompliance rokucapture rokuobs rokusleep rokumodes rokustart rokurelock rokuobsany rokureboot rokuobssoak rokusoakany q25 q25back"
[ "$SOURCE" != roku ] || { all="rokulock rokucompliance rokusleep rokumodes rokuobsany"; LOCAL_STEPS=$ROKU_STEPS; }
[ $# -gt 0 ] || set -- $all
for s in "$@"; do
	[ "$SOURCE" = roku ] || ! grep -qw -- "$s" <<< "$ROKU_STEPS" ||
		{ echo "step $s is the Roku's: GC573_SOURCE=roku GC573_LOCAL=1"; exit 2; }
done
if [ "$LOCAL" = 1 ]; then
	for s in "$@"; do
		grep -qw -- "$s" <<< "$LOCAL_STEPS" ||
			{ echo "step $s does not run here (local mode, source $SOURCE, runs: $LOCAL_STEPS)"; exit 2; }
	done
	[ -n "${SUDO_ASKPASS:-}" ] || sudo -n true 2>/dev/null ||
		{ echo "local mode needs sudo without a terminal: SUDO_ASKPASS, or cached credentials"; exit 2; }
fi
krel=$(vm uname -r) || exit 2
stamp=$(date -u +%Y%m%d-%H%M%S)
log=$ROOT/tests/logs/${stamp}_${krel}_live.log
mkdir -p "$ROOT/tests/logs"
# the run's event log, and the guard (tools/testsrc/guard.py): a test window
# outside the output, or test audio on any sink but the NVIDIA HDMI one,
# stops the run
export GC573_EVENT_LOG=${log%.log}-events.log GC573_GUARDED=1
python3 "$ROOT/tools/testsrc/guard.py" --pid $$ --log "$GC573_EVENT_LOG" --output "$OUT" &
if [ "$SOURCE" = roku ]; then
	trap 'roku_end' EXIT
elif [ "$LOCAL" = 1 ]; then
	trap 'colour_restore; "$ROOT/tools/testsrc/show.sh" --off; "$ROOT/tools/testsrc/avsync.sh" --off' EXIT
else
	trap 'colour_restore
		vm "[ ! -e $PW_RULE.off ] || { rm -f ~/$PW_WP; sudo mv $PW_RULE.off $PW_RULE; sudo udevadm control --reload;
			sudo udevadm trigger -s sound -c change; systemctl --user restart wireplumber; }"
		"$ROOT/tools/testsrc/show.sh" --off; "$ROOT/tools/testsrc/avsync.sh" --off
		ssh -O exit -o ControlPath="$SSHCTL" "$VM" 2>/dev/null' EXIT
fi
{
	echo "# GC573 live-input suite ($([ "$SOURCE" = roku ] && echo 'the Roku' || echo 'PC loopback'))"
	echo "date:    $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
	if [ "$LOCAL" = 1 ]; then
		echo "driver:  this host (local mode), kernel $krel"
	else
		echo "vm:      $VM, kernel $krel"
	fi
	echo "rev:     $(git -C "$ROOT" describe --always --dirty --abbrev=12)"
	if [ "$SOURCE" = roku ]; then
		echo "source:  the Roku ($(ecp info 2>&1)), go ${GC573_ROKU_GO:-0}"
	else
		echo "source:  host $(hostname) $OUT, $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null)"
	fi
	echo "steps:   $*"
	setup || { echo "setup failed"; exit 2; }
	kmark=$(date +%s%N)
	vm "echo 'gc573-live: $kmark' | sudo tee /dev/kmsg >/dev/null"
	kml reset
	load || { echo "cannot load the module"; exit 2; }
	if [ "$LOCAL" = 1 ]; then
		echo "module:  srcversion $(cat /sys/module/gc573/srcversion) loaded, $(modinfo -F filename gc573) $(modinfo -F srcversion gc573), $vdev"
	else
		echo "module:  srcversion $(vm "cat /sys/module/gc573/srcversion") loaded, $(vm "modinfo -F srcversion $VMDIR/gc573.ko") in ~/$VMDIR, $vdev"
	fi
	for s in "$@"; do
		echo
		echo "## $s"
		"step_$s"
	done
	echo
	echo "## test source"
	testsrc_check
	drv_mem_check
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
