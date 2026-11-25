#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# PC loopback test source: show an exact-value pattern on the host GPU output that is cabled to the
# GC573 HDMI IN (here: GT 710 DVI-D-0 -> DVI-to-HDMI cable -> HDMI IN). Host only, never in a VM.
# Usage: tools/testsrc/show.sh [OUTPUT [MODE [RATE]]]   default DVI-D-0 1920x1080 60
#        tools/testsrc/show.sh --off                    close the pattern window
# The output stays "disconnected" until a driver runs the HDMI chips (EDID loaded, HPD high).
# Sets OUTPUT right of the primary screen, turns NVIDIA dithering off on it (it adds +-1 temporal noise),
# and shows pattern.py's image full-screen there with ffplay.
# A watchdog closes the window as soon as OUTPUT disconnects (driver unload, card reset or move),
# so it never lands on the main screen. --off closes it explicitly.
set -euo pipefail
export DISPLAY=${DISPLAY:-:0} XAUTHORITY=${XAUTHORITY:-$HOME/.Xauthority}
run=${XDG_RUNTIME_DIR:-/tmp}/gc573-testsrc; mkdir -p "$run"; pidf=$run/ffplay.pid
wdf=$run/watchdog.pid
# An ffplay stopped within about a second of its start can hang for good in its
# SIGTERM exit path (main and SDL timer threads in futex wait): wait up to 2 s for
# each process to go, then SIGKILL.
stop() {
  local f p i
  for f in "$wdf" "$pidf"; do
    [ -f "$f" ] || continue
    p=$(cat "$f"); rm -f "$f"
    kill "$p" 2>/dev/null || continue
    for i in $(seq 20); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$p" 2>/dev/null; then kill -KILL "$p" 2>/dev/null || true; fi
  done
  return 0
}
if [ "${1:-}" = --off ]; then stop; exit 0; fi
out=${1:-DVI-D-0} mode=${2:-1920x1080} rate=${3:-60}
w=${mode%x*} h=${mode#*x}
xrandr --query | grep -q "^$out connected" || { echo "$out is not connected (HPD low?)" >&2; exit 1; }
primary=$(xrandr --query | awk '/ connected primary/{print $1; exit}')
xrandr --output "$out" --mode "$mode" --rate "$rate" --right-of "$primary"
command -v nvidia-settings >/dev/null && nvidia-settings --no-write-config -a "[DPY:$out]/Dithering=2" >/dev/null 2>&1 || true
x=$(xrandr --query | sed -n "s/^$out connected [^0-9]*[0-9]*x[0-9]*+\([0-9]*\)+.*/\1/p")
png=$run/pattern-${w}x$h.png
[ -f "$png" ] || "$(dirname "$0")/pattern.py" "$png" "$w" "$h" >/dev/null
stop
ffplay -loglevel error -noborder -left "$x" -top 0 -x "$w" -y "$h" -loop 0 -window_title gc573-pattern "$png" >/dev/null 2>&1 &
echo $! > "$pidf"
# --current: no re-probe; hotplug events keep RandR state current
setsid bash -c 'while kill -0 "$1" 2>/dev/null; do
  xrandr --current | grep -q "^$2 connected" || { kill "$1"; exit 0; }; sleep 1; done' _ "$(cat "$pidf")" "$out" \
  >/dev/null 2>&1 < /dev/null &
echo $! > "$wdf"
echo "pattern $png on $out ($mode@$rate at +$x+0), pid $(cat "$pidf")"
