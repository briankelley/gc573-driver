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
# saved and restored by --off. Audio goes only to that port, never to the
# default sink.
# A watchdog runs --off when OUTPUT disconnects (driver unload, card reset or move).
# Usage: tools/testsrc/avsync.sh [OUTPUT [MODE [RATE]]] | --off
#   RATE: 60, 59.94, 50, 30, 29.97, 25, 24 or 23.976 (default 60)
set -euo pipefail
export DISPLAY=${DISPLAY:-:0} XAUTHORITY=${XAUTHORITY:-$HOME/.Xauthority}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
run=$XDG_RUNTIME_DIR/gc573-testsrc; mkdir -p "$run"
pidf=$run/avsync.pid wdf=$run/avsync-watchdog.pid statef=$run/avsync.state
here=$(cd "$(dirname "$0")" && pwd)

off() {
  for f in "$wdf" "$pidf"; do
    if [ -f "$f" ]; then kill "$(cat "$f")" 2>/dev/null || true; fi
    rm -f "$f"
  done
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

out=${1:-DVI-D-0} mode=${2:-1920x1080} rate=${3:-60}
w=${mode%x*} h=${mode#*x}
case $rate in
  59.94) fps=60000/1001 n=60 ;;
  29.97) fps=30000/1001 n=30 ;;
  23.976) fps=24000/1001 n=24 ;;
  60|50|30|25|24) fps=$rate n=$rate ;;
  *) echo "unsupported rate $rate" >&2; exit 2 ;;
esac
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

"$here/show.sh" --off
off
printf '%s\n%s\n%s\n' "$card" "$(cardinfo | sed -n 's/^\tActive Profile: //p')" "$(pactl get-default-sink)" > "$statef"
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
xrandr --output "$out" --mode "$mode" --rate "$rate" --right-of "$primary"
command -v nvidia-settings >/dev/null && nvidia-settings --no-write-config -a "[DPY:$out]/Dithering=2" >/dev/null 2>&1 || true
x=$(xrandr --query | sed -n "s/^$out connected [^0-9]*[0-9]*x[0-9]*+\([0-9]*\)+.*/\1/p")

# flash: frame index multiple of n; burst: the same instant, one frame long
period="($n/($fps))" frame="(1/($fps))"
graph="color=c=black:s=${w}x$h:r=$fps,format=rgb24,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='eq(mod(n\\,$n)\\,0)'[out0];"
# aevalsrc gates per sample (a filter's enable= only switches per 1024-sample frame)
gate="lt(mod(t\\,$period)\\,$frame)"
graph+="aevalsrc=exprs='0.5*sin(2*PI*1000*t)*$gate|0.5*sin(2*PI*2000*t)*$gate':channel_layout=stereo:sample_rate=48000,aformat=sample_fmts=s16[out1]"
PULSE_SINK=$sink SDL_AUDIODRIVER=pulseaudio setsid ffplay -loglevel error -noborder -left "$x" -top 0 -x "$w" -y "$h" \
  -window_title gc573-avsync -f lavfi -i "$graph" >/dev/null 2>&1 < /dev/null &
echo $! > "$pidf"
setsid bash -c 'while kill -0 "$1" 2>/dev/null; do
  xrandr --current | grep -q "^$2 connected" || { "$3" --off; exit 0; }; sleep 1; done' _ "$(cat "$pidf")" "$out" "$here/avsync.sh" \
  >/dev/null 2>&1 < /dev/null &
echo $! > "$wdf"
echo "avsync on $out ($mode@$rate at +$x+0): flash every $n frames, burst L 1 kHz / R 2 kHz on $sink; pid $(cat "$pidf")"
