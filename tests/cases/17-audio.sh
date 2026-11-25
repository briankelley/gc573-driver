#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M4: ALSA capture with no HDMI input (gc573_input_off). Without an input
# the FPGA still completes a period every 10 ms (spec/audio.md "Running")
# and writes zeros, so a stream runs: 48 kHz against the clock, no
# overrun, silence, AUDIO_DONE in order, INT bit 4 at every stop. Then the
# PCM's hw params (S16_LE, 2 channels, 48 kHz only, periods in steps of
# 480 frames), 20 stop/start cycles, audio across 3 video stream
# start/stops and across 30 video stop/start cycles in every format (while
# audio runs the video stop leaves out reset domain 8, which holds the
# audio DMA, open question 13: no DMA restart, nothing filled, AUDIO_DONE
# in order, rate within 0.1 %), rmmod refused while the PCM is open, unbind
# while capturing (the application sees an error and exits, unbind < 5 s)
# and a capture after the rebind. SKIP without the alsa-lib headers.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

drv=/sys/bus/pci/drivers/$GC573_MOD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
[ -e /usr/include/alsa/asoundlib.h ] || skip "alsa-lib headers (libasound2-dev) not installed"
aud=$(gc573_aud_build "$tmp") || fail "cannot build gc573-aud"
cap=$(gc573_cap_build "$tmp") || fail "cannot build gc573-cap"

gc573_load || fail "insmod failed"
dev=$(gc573_video_dev) || { gc573_unload; fail "no video node"; }
pcm=$(gc573_pcm) || { gc573_unload; fail "no ALSA card"; }
gc573_input_off "$dev"
echo "PCM $pcm, video $dev"
bad=0
check() {	# condition result, text
	if [ "$1" = 0 ]; then echo "ok: $2"; else echo "FAILED: $2"; bad=1; fi
}
# frames, secs, rate, xruns from a gc573-aud RESULT line in file $1
result_of() {
	sed -n 's/^RESULT audio frames=\([0-9]*\) secs=\([0-9.]*\) rate=\([0-9.]*\) xruns=\([0-9]*\).*/\1 \2 \3 \4/p' "$1"
}
near() {	# value, target, tolerance (awk floats)
	awk -v v="$1" -v t="$2" -v d="$3" 'BEGIN { exit !(v >= t - d && v <= t + d) }'
}

# hw params
arecord -D "$pcm" --dump-hw-params -d 1 -f S16_LE -r 48000 -c 2 /dev/null > "$tmp/hw" 2>&1
sed -n '/^FORMAT/p; /^CHANNELS/p; /^RATE/p; /^PERIOD_SIZE/p; /^BUFFER_SIZE/p' "$tmp/hw" | sed 's/^/  /'
check "$(grep -qE '^FORMAT: +S16_LE$' "$tmp/hw" && grep -qE '^CHANNELS: 2$' "$tmp/hw" &&
	grep -qE '^RATE: 48000$' "$tmp/hw" && grep -qE '^PERIOD_SIZE: \[480 ' "$tmp/hw"; echo $?)" \
	"hw params: S16_LE, 2 channels, 48000 Hz, periods from 480 frames"

# 3 s: frames against the clock, no overrun, silence, counters
p0=$(gc573_aud_stat periods) s0=$(gc573_aud_stat silent)
o0=$(gc573_aud_stat order) b0=$(gc573_aud_stat bad_done)
"$aud" -D "$pcm" -t 3 -v > "$tmp/a1" 2>&1
rc=$?
grep -E '^(RESULT|XRUN)' "$tmp/a1" | sed 's/^/  /'
read -r frames secs rate xruns <<< "$(result_of "$tmp/a1")"
loud=$(grep -c '^A .* peak=\([1-9]\|0,[1-9]\)' "$tmp/a1")
dp=$(( $(gc573_aud_stat periods) - p0 )) ds=$(( $(gc573_aud_stat silent) - s0 ))
check "$([ "$rc" = 0 ] && [ "${xruns:-1}" = 0 ]; echo $?)" "capture ran, no overrun"
check "$(near "${rate:-0}" 48000 48; echo $?)" "rate $rate Hz (48000 +- 0.1 %), $frames frames in $secs s"
check "$([ "$loud" = 0 ]; echo $?)" "all samples zero ($loud reads with a sample)"
check "$([ "$dp" -ge 295 ] && [ "$dp" = "$ds" ]; echo $?)" \
	"$dp periods, $ds of them delivered as silence (no input)"
check "$([ "$(gc573_aud_stat order)" = "$o0" ] && [ "$(gc573_aud_stat bad_done)" = "$b0" ]; echo $?)" \
	"AUDIO_DONE alternated 1, 2 (order, bad_done unchanged)"

# 20 stop/start cycles
st0=$(gc573_aud_stat starts) sp0=$(gc573_aud_stat stops) m0=$(gc573_aud_stat stop_missing)
"$aud" -D "$pcm" -t 5.1 -s 0.25 > "$tmp/a2" 2>&1
rc=$?
read -r frames secs rate xruns <<< "$(result_of "$tmp/a2")"
dst=$(( $(gc573_aud_stat starts) - st0 )) dsp=$(( $(gc573_aud_stat stops) - sp0 ))
check "$([ "$rc" = 0 ] && [ "${xruns:-1}" = 0 ] && [ "$dst" -ge 20 ] && [ "$dst" = "$dsp" ] &&
	[ "$(gc573_aud_stat stop_missing)" = "$m0" ]; echo $?)" \
	"stop/start: $dst starts, $dsp INT bit 4, no overrun, no stop without INT bit 4"

# audio across 3 video stream start/stops
r0=$(gc573_aud_stat restarts) f0=$(gc573_aud_stat filled)
"$aud" -D "$pcm" -t 9 -v > "$tmp/a3" 2>&1 &
apid=$!
sleep 1.5
vrc=0
for i in 1 2 3; do
	"$cap" -d "$dev" -f YUYV -b 4 -n 60 > "$tmp/v$i" 2>&1 || vrc=1
	sleep 0.7
done
wait "$apid"
rc=$?
read -r frames secs rate xruns <<< "$(result_of "$tmp/a3")"
dr=$(( $(gc573_aud_stat restarts) - r0 )) df=$(( $(gc573_aud_stat filled) - f0 ))
check "$([ "$vrc" = 0 ]; echo $?)" "3 video captures"
check "$([ "$rc" = 0 ] && [ "${xruns:-1}" = 0 ] && [ "$dr" = 0 ] && [ "$df" = 0 ]; echo $?)" \
	"audio through them: no overrun, $dr DMA restarts, $df frames of silence filled (the video stops leave the audio domain alone)"
check "$([ "${frames:-0}" -ge $((48000 * 85 / 10)) ]; echo $?)" \
	"$frames frames in the 9 s run: no stall (>= 8.5 s worth)"
check "$(near "${rate:-0}" 48000 48; echo $?)" \
	"rate across them $rate Hz (48000 +- 0.1 %: a 90 ms gap would be -1 %)"

# video stop/start stress, the six formats in turn, while audio runs
r0=$(gc573_aud_stat restarts) f0=$(gc573_aud_stat filled) o0=$(gc573_aud_stat order)
"$aud" -D "$pcm" -t 12 > "$tmp/a5" 2>&1 &
apid=$!
sleep 1
"$cap" -d "$dev" -f all -b 4 -n 3 -c 30 > "$tmp/v5" 2>&1
vrc=$?
wait "$apid"
rc=$?
read -r frames secs rate xruns <<< "$(result_of "$tmp/a5")"
dr=$(( $(gc573_aud_stat restarts) - r0 )) df=$(( $(gc573_aud_stat filled) - f0 ))
dor=$(( $(gc573_aud_stat order) - o0 ))
check "$([ "$vrc" = 0 ]; echo $?)" \
	"video stop/start stress while audio runs: $(grep -m1 '^RESULT cycles' "$tmp/v5" || echo 'no RESULT')"
check "$([ "$rc" = 0 ] && [ "${xruns:-1}" = 0 ] && [ "$dr" = 0 ] && [ "$df" = 0 ] &&
	[ "$dor" = 0 ] && near "${rate:-0}" 48000 48; echo $?)" \
	"audio through them: no overrun, $dr DMA restarts, $df frames filled, AUDIO_DONE out of turn $dor, $rate Hz"

# rmmod while the PCM is open, unbind while capturing, rebind
"$aud" -D "$pcm" -t 60 > "$tmp/a4" 2>&1 &
apid=$!
sleep 1
rmmod "$GC573_MOD" > "$tmp/rm" 2>&1
rrc=$?
check "$([ "$rrc" != 0 ] && grep -q 'in use' "$tmp/rm"; echo $?)" "rmmod refused while open ($(head -1 "$tmp/rm"))"
t0=$(date +%s%N)
timeout 5 sh -c "echo $GC573_BDF > $drv/unbind"
urc=$?
t1=$(date +%s%N)
for _ in $(seq 50); do
	kill -0 "$apid" 2>/dev/null || break
	sleep 0.1
done
if kill -0 "$apid" 2>/dev/null; then
	kill "$apid"
	check 1 "capture still running 5 s after unbind"
fi
wait "$apid"
arc=$?
check "$([ "$urc" = 0 ] && [ "$arc" != 0 ]; echo $?)" \
	"unbind while capturing: exit $urc after $(( (t1 - t0) / 1000000 )) ms; capture exited with $arc"
gc573_bound && { gc573_unload; fail "still bound after unbind"; }
echo "$GC573_BDF" > "$drv/bind" || { gc573_unload; fail "rebind failed"; }
pcm=$(gc573_pcm) || { gc573_unload; fail "no ALSA card after rebind"; }
"$aud" -D "$pcm" -t 1 > "$tmp/a5" 2>&1
rc=$?
read -r frames secs rate xruns <<< "$(result_of "$tmp/a5")"
check "$([ "$rc" = 0 ] && [ "${frames:-0}" -ge 45000 ]; echo $?)" "capture after rebind: $frames frames"

gc573_unload || fail "rmmod failed"
[ "$bad" = 0 ] || fail "see above"
echo "audio without input: OK"
