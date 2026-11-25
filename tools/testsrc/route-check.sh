#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Check that avsync.sh's audio never reaches another sink (host only, with
# gc573 loaded in the VM and nothing holding it there). The player runs silent
# (--amplitude 0) while its sink is pulled away under it, without closing it
# first as the tests otherwise do:
#   off      DVI-D-0 switched off, then on again (avsync.sh restarted)
#   rate     1080p60 -> 1080p59.94 set directly: same geometry, so the player
#            keeps running through the mode set
#   size     1080p -> 720p set directly: the watchdog closes the player
#   edid     VIDIOC_S_EDID with another image, then the default (hot-plug pulses)
#   unload   gc573 unloaded in the VM (the card's HPD goes low), loaded again
#   restart  avsync.sh started again while it runs
# tools/testsrc/guard.py --other-outputs watches it every 50 ms: a link from
# the player's stream to any sink but the NVIDIA HDMI one, or a test window
# overlapping another output, stops the run. The default sink's monitor (the
# user's speaker) is recorded meanwhile; only its peak is kept.
# Log: DIR/route-check.log (the guard's lines and every action, UTC ms).
# Usage: tools/testsrc/route-check.sh DIR
set -u
dir=${1:?usage: route-check.sh DIR}
mkdir -p "$dir"
here=$(cd "$(dirname "$0")" && pwd)
export DISPLAY=${DISPLAY:-:0} XAUTHORITY=${XAUTHORITY:-$HOME/.Xauthority}
export GC573_EVENT_LOG=$dir/route-check.log
VM=${VM:-gc573-dev} OUT=DVI-D-0
log() { echo "$(date -u +%FT%T.%3NZ) check $*" >> "$GC573_EVENT_LOG"; echo "$*"; }
vm() { ssh -n -o BatchMode=yes "$VM" "$@"; }
connected() { xrandr --current | grep -q "^$OUT connected"; }
wait_connected() { for _ in $(seq 100); do connected && return 0; sleep 0.1; done; return 1; }
av() {	# the output on with show.sh first (a valid ELD needs it), then avsync.sh
	local i
	"$here/show.sh" "$OUT" 1920x1080 60 > /dev/null || return 1
	for i in $(seq 30); do
		"$here/avsync.sh" --pattern --amplitude 0 "$OUT" 1920x1080 60 > /dev/null 2>&1 && return 0
		sleep 0.5
	done
	return 1
}

sink=$(pactl get-default-sink)
python3 "$here/guard.py" --pid $$ --log "$GC573_EVENT_LOG" --other-outputs &
gpid=$!
parecord --device="$sink.monitor" --file-format=wav --channels=2 --rate=48000 --format=s16le "$dir/monitor.wav" &
rpid=$!
log "start: guard pid $gpid; recording the monitor of $sink (the default sink)"
sleep 1

log "avsync start (silent)"; av || log "FAIL: avsync did not start"; sleep 3
log "off: output off under the player"; xrandr --output "$OUT" --off; sleep 4
log "off: output on, avsync again"; av || log "FAIL: avsync did not start"; sleep 3
log "rate: 1080p59.94 set under the player"; xrandr --output "$OUT" --mode 1920x1080 --rate 59.94; sleep 4
log "rate: 1080p60 set under the player"; xrandr --output "$OUT" --mode 1920x1080 --rate 60; sleep 4
log "size: 720p set under the player"; xrandr --output "$OUT" --mode 1280x720 --rate 59.94; sleep 4
log "size: back to 1080p60, avsync again"; av || log "FAIL: avsync did not start"; sleep 3
vm "d=/tmp/gc573-route; mkdir -p \$d; v=\$(ls /dev/v4l/by-path/*-video-index0 | head -1);
	v4l2-ctl -d \$v --get-edid=file=\$d/default.bin,format=raw > /dev/null &&
	python3 -c \"import sys; d=bytearray(open(sys.argv[1],'rb').read()); d[0x0c]^=0x5a; d[0x7f]=-sum(d[0:0x7f]) & 0xff; open(sys.argv[2],'wb').write(d)\" \$d/default.bin \$d/other.bin"
log "edid: another image under the player"
vm 'v4l2-ctl -d $(ls /dev/v4l/by-path/*-video-index0 | head -1) --set-edid=file=/tmp/gc573-route/other.bin,format=raw'
sleep 4
log "edid: the default image again"
vm 'v4l2-ctl -d $(ls /dev/v4l/by-path/*-video-index0 | head -1) --set-edid=file=/tmp/gc573-route/default.bin,format=raw'
sleep 3; wait_connected; log "edid: avsync again"; av || log "FAIL: avsync did not start"; sleep 3
log "unload: driver unload in the VM under the player"; vm 'sudo rmmod gc573' || log "FAIL: rmmod"
sleep 5
log "unload: driver load in the VM"; vm 'sudo insmod ~/gc573-driver/gc573.ko' || log "FAIL: insmod"
wait_connected || log "FAIL: output not connected after the load"
sleep 3; log "unload: avsync again"; av || log "FAIL: avsync did not start"; sleep 3
log "restart: avsync.sh again while it runs"
"$here/avsync.sh" --pattern --amplitude 0 "$OUT" 1920x1080 60 > /dev/null || log "FAIL: restart"
sleep 3
log "stop: avsync --off"; "$here/avsync.sh" --off; "$here/show.sh" --off; sleep 1
kill "$rpid"; wait "$rpid" 2>/dev/null
peak=$(python3 -c "
import sys, wave, array
w = wave.open(sys.argv[1]); a = array.array('h', w.readframes(w.getnframes()))
print(f'{max((abs(x) for x in a), default=0)} over {len(a) // 2 / 48000:.1f} s')" "$dir/monitor.wav")
rm -f "$dir/monitor.wav"
log "monitor of $sink: peak |sample| $peak (0: digital silence)"
log "end"
# the guard ends once this script has (it watches it): its last line follows
echo "breaches so far: $(grep -c 'BREACH' "$GC573_EVENT_LOG")"
