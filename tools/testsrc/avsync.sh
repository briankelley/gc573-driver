#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# A/V test source on the PC loopback (host only).
# Shows a black full-screen clip on OUTPUT that turns white for one frame every
# N frames (N = the nominal rate, so about once per second), and plays a tone
# burst of one frame's length at the same instant on the GPU's HDMI audio:
# 1 kHz on the left channel, 2 kHz on the right (identifies channel order).
# Captured through the card, the flash frame and the burst onset give the A/V
# offset and its drift. The source's own offset is not known exactly (player and
# GPU latency), so compare runs and watch drift rather than trusting absolutes.
#
# Audio: the NVIDIA HDMI audio card is switched to the profile of the single HDMI
# port that has a valid ELD (the capture card, once its EDID with an audio block
# is loaded and HPD is high). The previous card profile and default sink are
# saved and restored by --off; a start while a session runs keeps what the
# first start saved. The player's audio never reaches another sink: it plays
# through PipeWire's own API (SDL_AUDIODRIVER=pipewire) as node gc573-avsync,
# with that HDMI sink as its target (PIPEWIRE_NODE) and node.dont-reconnect set.
# When the sink goes away (output off, unplugged, a profile change), WirePlumber
# destroys the stream instead of moving it to the default sink, and the player
# goes on silent. The start fails unless the stream is linked to that sink alone.
# The test window never shows on the main screen (as show.sh): every test
# player is closed before anything else (a check that fails leaves none
# behind), and before the mode is set; the window is override-redirect, so the
# window manager never moves it (window-check.sh verifies it, or the player is
# closed); and a watchdog (watchdog.sh) runs --off within 0.2 s once OUTPUT no
# longer shows the player's geometry (output off, unplugged, another mode).
# tools/testsrc/guard.py watches both rules for a whole test run.
#
# --pattern: the picture is pattern.py's exact-value pattern with a frame
# counter, and the flash a box in its bottom band (counter-graph.sh), for
# checks that need both a known image and liveness (tests/obs-events.py).
# --amplitude A: the bursts' amplitude, 0 to 1 (default 0.5); 0 plays digital
# silence, for checks of the audio routing that must not make a sound.
# GC573_EVENT_LOG=FILE: append a line per action (UTC, milliseconds) to FILE.
# Usage: tools/testsrc/avsync.sh [--pattern] [--amplitude A] [OUTPUT [MODE [RATE]]] | --off
#   RATE: 60, 59.94, 50, 30, 29.97, 25, 24 or 23.976 (default 60)
set -euo pipefail
export DISPLAY=${DISPLAY:-:0} XAUTHORITY=${XAUTHORITY:-$HOME/.Xauthority}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
run=$XDG_RUNTIME_DIR/gc573-testsrc; mkdir -p "$run"
pidf=$run/avsync.pid wdf=$run/avsync-watchdog.pid statef=$run/avsync.state
here=$(cd "$(dirname "$0")" && pwd)

evlog() { [ -z "${GC573_EVENT_LOG:-}" ] || echo "$(date -u +%FT%T.%3NZ) avsync $*" >> "$GC573_EVENT_LOG"; }

# Stop the player and its watchdog. An ffplay stopped within about a second of
# its start can hang in its exit path: wait up to 2 s each, then SIGKILL (as
# show.sh does).
stop_procs() {
  local f p i
  for f in "$wdf" "$pidf"; do
    [ -f "$f" ] || continue
    p=$(cat "$f"); rm -f "$f"
    kill "$p" 2>/dev/null || continue
    [ "$f" = "$pidf" ] && evlog "player stop (pid $p)"
    for i in $(seq 20); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$p" 2>/dev/null; then kill -KILL "$p" 2>/dev/null || true; fi
  done
}
off() {
  stop_procs
  if [ -f "$statef" ]; then
    local card profile0 sink0
    { read -r card; read -r profile0; read -r sink0; } < "$statef"
    pactl set-card-profile "$card" "$profile0" 2>/dev/null || true
    if [ -n "$sink0" ]; then pactl set-default-sink "$sink0" 2>/dev/null || true; fi
    rm -f "$statef"
  fi
  return 0
}
if [ "${1:-}" = --off ]; then off; exit 0; fi
pattern=0 amp=0.5
while [ $# -gt 0 ]; do
  case $1 in
    --pattern) pattern=1; shift ;;
    --amplitude) amp=${2:?--amplitude needs a value}; shift 2 ;;
    *) break ;;
  esac
done
awk -v a="$amp" 'BEGIN { exit !(a ~ /^[0-9.]+$/ && a >= 0 && a <= 1) }' ||
  { echo "amplitude $amp: want 0 to 1" >&2; exit 2; }

out=${1:-DVI-D-0} mode=${2:-1920x1080} rate=${3:-60}
w=${mode%x*} h=${mode#*x}
case $rate in
  59.94) fps=60000/1001 n=60 ;;
  29.97) fps=30000/1001 n=30 ;;
  23.976) fps=24000/1001 n=24 ;;
  60|50|30|25|24) fps=$rate n=$rate ;;
  *) echo "unsupported rate $rate" >&2; exit 2 ;;
esac

# no test player may outlive a failed check below, nor exist while the mode changes
"$here/show.sh" --off
stop_procs

xrandr --query | grep -q "^$out connected" || { echo "$out is not connected (HPD low?)" >&2; exit 1; }

# NVIDIA HDMI audio card in PipeWire: alsa_card.pci-<domain>_<bus>_<slot>.<fn>
addr=$(lspci -D -d 10de: | awk '/Audio/{print $1; exit}')
[ -n "$addr" ] || { echo "no NVIDIA HDMI audio function" >&2; exit 1; }
card=alsa_card.pci-${addr//:/_}
cardinfo() { pactl list cards | awk -v C="Name: $card" '$0 ~ C {f=1; next} f && /^Card #/ {exit} f'; }
ports=$(cardinfo | sed -n 's/^\t\t\(hdmi-output-[0-9]\): .*[^t] available)$/\1/p')
[ "$(printf '%s\n' "$ports" | grep -c .)" = 1 ] ||
  { echo "need exactly one HDMI audio port with a valid ELD, have: ${ports:-none}" >&2; exit 1; }
i=${ports#hdmi-output-}
if [ "$i" = 0 ]; then prof=output:hdmi-stereo; else prof=output:hdmi-stereo-extra$i; fi

# A session that is running (a restart) or was cut off keeps the profile and
# default sink it saved before its first start. Restoring here and reading the
# profile back at once can race, and would record our own profile as the one
# to restore.
if [ ! -f "$statef" ]; then
  printf '%s\n%s\n%s\n' "$card" "$(cardinfo | sed -n 's/^\tActive Profile: //p')" "$(pactl get-default-sink)" > "$statef"
fi
pactl set-card-profile "$card" "$prof"
sink=
for _ in $(seq 1 20); do
  sink=$(pactl list short sinks | awk -v c="alsa_output.${card#alsa_card.}." 'index($2, c) == 1 {print $2; exit}')
  [ -n "$sink" ] && break; sleep 0.25
done
[ -n "$sink" ] || { off; echo "no sink appeared for $prof" >&2; exit 1; }
# PipeWire may make the new sink the default: put the saved default back
sink0=$(sed -n 3p "$statef"); [ -z "$sink0" ] || pactl set-default-sink "$sink0"
pactl set-sink-mute "$sink" 0; pactl set-sink-volume "$sink" 100%

primary=$(xrandr --query | awk '/ connected primary/{print $1; exit}')
[ -n "$primary" ] && [ "$primary" != "$out" ] || { off; echo "no primary output other than $out" >&2; exit 1; }
evlog "mode $out $mode@$rate"
xrandr --output "$out" --mode "$mode" --rate "$rate" --right-of "$primary"
command -v nvidia-settings >/dev/null && nvidia-settings --no-write-config -a "[DPY:$out]/Dithering=2" >/dev/null 2>&1 || true
x=$(xrandr --query | sed -n "s/^$out connected \(primary \)\?${w}x$h+\([0-9]*\)+0 .*/\2/p")
[ -n "$x" ] || { off; echo "$out does not show ${w}x$h after the mode set" >&2; exit 1; }

# flash: frame index multiple of n; burst: the same instant, one frame long
period="($n/($fps))" frame="(1/($fps))"
if [ "$pattern" = 1 ]; then
  png=$run/pattern-${w}x$h.png
  [ -f "$png" ] || "$here/pattern.py" "$png" "$w" "$h" >/dev/null
  graph="$("$here/counter-graph.sh" "$png" "$w" "$h" "$fps" "$n")[out0];"
else
  graph="color=c=black:s=${w}x$h:r=$fps,format=rgb24,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='eq(mod(n\\,$n)\\,0)'[out0];"
fi
# aevalsrc gates per sample (a filter's enable= only switches per 1024-sample frame)
gate="lt(mod(t\\,$period)\\,$frame)"
graph+="aevalsrc=exprs='$amp*sin(2*PI*1000*t)*$gate|$amp*sin(2*PI*2000*t)*$gate':channel_layout=stereo:sample_rate=48000,aformat=sample_fmts=s16[out1]"
SDL_AUDIODRIVER=pipewire PIPEWIRE_NODE=$sink \
  PIPEWIRE_PROPS="{ node.name = gc573-avsync node.description = gc573-avsync node.dont-reconnect = true }" \
  SDL_X11_FORCE_OVERRIDE_REDIRECT=1 setsid ffplay -loglevel error \
  -noborder -left "$x" -top 0 -x "$w" -y "$h" -window_title gc573-avsync -f lavfi -i "$graph" >/dev/null 2>&1 < /dev/null &
echo $! > "$pidf"
setsid "$here/watchdog.sh" "$(cat "$pidf")" "$out" "$w" "$h" "$x" "$here/avsync.sh" --off \
  >/dev/null 2>&1 < /dev/null &
echo $! > "$wdf"
if ! chk=$("$here/window-check.sh" gc573-avsync "$w" "$h" "$x"); then
  off
  echo "test window not as required, closed: $chk" >&2
  exit 1
fi
# the stream: linked to the HDMI sink and nothing else
links=
for _ in $(seq 30); do
  links=$(pw-link -l 2>/dev/null | awk '/^gc573-avsync:/ { p = $1; next } /^ *\|-> / && p { print p " -> " $2 } /^[^ ]/ { p = "" }')
  [ -n "$links" ] && break
  sleep 0.1
done
if [ -z "$links" ] || grep -qv " -> $sink:" <<< "$links"; then
  off
  echo "the player's audio is not linked to $sink alone: ${links:-no link}" >&2
  exit 1
fi
evlog "player start $mode@$rate$([ "$pattern" = 0 ] || echo " pattern") amplitude $amp (pid $(cat "$pidf"))"
echo "avsync on $out ($mode@$rate at +$x+0)$([ "$pattern" = 0 ] || echo ", pattern with counter"): flash every $n frames, burst L 1 kHz / R 2 kHz, amplitude $amp, on $sink alone ($(wc -l <<< "$links") links); pid $(cat "$pidf"); $chk"
