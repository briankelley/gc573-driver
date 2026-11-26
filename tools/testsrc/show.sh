#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# PC loopback test source: show an exact-value pattern on the host GPU output that is cabled to the
# GC573 HDMI IN (here: GT 710 DVI-D-0 -> DVI-to-HDMI cable -> HDMI IN). Host only, never in a VM.
# Usage: tools/testsrc/show.sh [--counter] [OUTPUT [MODE [RATE]]]   default DVI-D-0 1920x1080 60
#        tools/testsrc/show.sh --off                    close the pattern window
# --counter: the pattern with a frame counter and a flash box in its bottom band
# (counter-graph.sh; RATE 60, 59.94, 50, 30, 29.97, 25, 24 or 23.976), so that a
# check can tell a new frame from a repeated one (tests/obs-events.py).
# The output stays "disconnected" until a driver runs the HDMI chips (EDID loaded, HPD high).
# Sets OUTPUT right of the primary screen, turns NVIDIA dithering off on it (it adds +-1 temporal noise),
# and shows pattern.py's image full-screen there with ffplay.
# The test window must never show on the main screen:
# - Every test player (this one's, avsync.sh's) is closed before the mode is set: the
#   window manager moves the windows it manages from an output that loses its mode
#   to the primary one.
# - The player's window is override-redirect (SDL_X11_FORCE_OVERRIDE_REDIRECT=1): the
#   window manager never manages or moves it. While its output is off it sits off-screen.
#   window-check.sh verifies that, and its place on OUTPUT, or the player is closed.
# - ffplay runs with place.so (place.c, built by place.sh). The window is created at its
#   final geometry on OUTPUT and never has another, mapped or not. It is mapped only after
#   a check under a server grab: override-redirect, at that geometry, inside OUTPUT's
#   RandR monitor and overlapping no other. Otherwise the player exits without a window.
#   (Without it, SDL creates the window hidden on the primary output and moves it before
#   the map.)
# - A watchdog (watchdog.sh) closes it within 0.2 s once OUTPUT no longer shows the
#   player's geometry: output off, unplugged (driver unload, card reset or move), another
#   mode. --off closes it explicitly.
# - The players close before any check can exit, so a failed start leaves none behind.
#   tools/testsrc/guard.py watches the windows for a whole test run.
# The player has no audio (-an).
# GC573_EVENT_LOG=FILE: append a line per action (UTC, milliseconds) to FILE.
set -euo pipefail
export DISPLAY=${DISPLAY:-:0} XAUTHORITY=${XAUTHORITY:-$HOME/.Xauthority}
run=${XDG_RUNTIME_DIR:-/tmp}/gc573-testsrc; mkdir -p "$run"; pidf=$run/ffplay.pid
wdf=$run/watchdog.pid
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tools/testsrc/scrub.sh
. "$here/scrub.sh"	# gc573_scrub: no USB serial in a log
evlog() { [ -z "${GC573_EVENT_LOG:-}" ] || echo "$(date -u +%FT%T.%3NZ) show $(gc573_scrub "$*")" >> "$GC573_EVENT_LOG"; }
# An ffplay stopped within about a second of its start can hang for good in its
# SIGTERM exit path (main and SDL timer threads in futex wait): wait up to 2 s for
# each process to go, then SIGKILL.
stop() {
  local f p i
  for f in "$wdf" "$pidf"; do
    [ -f "$f" ] || continue
    p=$(cat "$f"); rm -f "$f"
    kill "$p" 2>/dev/null || continue
    [ "$f" = "$pidf" ] && evlog "player stop (pid $p)"
    for i in $(seq 20); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$p" 2>/dev/null; then kill -KILL "$p" 2>/dev/null || true; fi
  done
  return 0
}
if [ "${1:-}" = --off ]; then stop; exit 0; fi
counter=0
if [ "${1:-}" = --counter ]; then counter=1; shift; fi
out=${1:-DVI-D-0} mode=${2:-1920x1080} rate=${3:-60}
w=${mode%x*} h=${mode#*x}
case $rate in
  59.94) fps=60000/1001 n=60 ;;
  29.97) fps=30000/1001 n=30 ;;
  23.976) fps=24000/1001 n=24 ;;
  *) fps=$rate n=${rate%%.*} ;;
esac
# no test player may outlive a failed check below, nor exist while the mode changes
"$here/avsync.sh" --off
stop
place=$("$here/place.sh") || { echo "cannot build the window placement library ($here/place.c)" >&2; exit 1; }
xrandr --query | grep -q "^$out connected" || { echo "$out is not connected (HPD low?)" >&2; exit 1; }
primary=$(xrandr --query | awk '/ connected primary/{print $1; exit}')
[ -n "$primary" ] && [ "$primary" != "$out" ] || { echo "no primary output other than $out" >&2; exit 1; }
evlog "mode $out $mode@$rate"
xrandr --output "$out" --mode "$mode" --rate "$rate" --right-of "$primary"
command -v nvidia-settings >/dev/null && nvidia-settings --no-write-config -a "[DPY:$out]/Dithering=2" >/dev/null 2>&1 || true
x=$(xrandr --query | sed -n "s/^$out connected \(primary \)\?${w}x$h+\([0-9]*\)+0 .*/\2/p")
[ -n "$x" ] || { echo "$out does not show ${w}x$h after the mode set" >&2; exit 1; }
png=$run/pattern-${w}x$h.png
[ -f "$png" ] || "$here/pattern.py" "$png" "$w" "$h" >/dev/null
err=$run/ffplay.err
if [ "$counter" = 1 ]; then
  LD_PRELOAD=$place GC573_PLACE="$x 0 $w $h $out" SDL_X11_FORCE_OVERRIDE_REDIRECT=1 \
    ffplay -loglevel error -an -noborder -left "$x" -top 0 -x "$w" -y "$h" \
    -window_title gc573-pattern -f lavfi -i "$("$here/counter-graph.sh" "$png" "$w" "$h" "$fps" "$n")" \
    >/dev/null 2> "$err" < /dev/null &
else
  LD_PRELOAD=$place GC573_PLACE="$x 0 $w $h $out" SDL_X11_FORCE_OVERRIDE_REDIRECT=1 \
    ffplay -loglevel error -an -noborder -left "$x" -top 0 -x "$w" -y "$h" -loop 0 \
    -window_title gc573-pattern "$png" >/dev/null 2> "$err" < /dev/null &
fi
pid=$!
echo "$pid" > "$pidf"
setsid "$here/watchdog.sh" "$pid" "$out" "$w" "$h" "$x" >/dev/null 2>&1 < /dev/null &
echo $! > "$wdf"
if ! chk=$("$here/window-check.sh" gc573-pattern "$w" "$h" "$x" "$pid"); then
  stop
  echo "test window not as required, closed: $chk $(tr '\n' ' ' < "$err")" >&2
  exit 1
fi
grep -q "^gc573-place: mapped at ${w}x$h+$x+0 on $out\$" "$err" || {
  stop; echo "the test window was not placed by place.so: $(tr '\n' ' ' < "$err")" >&2; exit 1; }
# closed meanwhile (--off, avsync.sh, guard.py): there is no start to report
if ! kill -0 "$pid" 2>/dev/null || [ "$(cat "$pidf" 2>/dev/null)" != "$pid" ]; then
  stop
  echo "the player (pid $pid) was closed while it started" >&2
  exit 1
fi
evlog "player start $mode@$rate$([ "$counter" = 0 ] || echo " counter") (pid $pid)"
echo "pattern $png$([ "$counter" = 0 ] || echo " with counter") on $out ($mode@$rate at +$x+0), pid $pid; $chk"
