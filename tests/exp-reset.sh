#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Experiment, spec/open-questions.md #13: what each reset domain (RESET 0x00c
# bits 0, 8, 9) resets, and which one stops the audio DMA. Runs in gc573-dev
# as root, with the module loaded (tools/vmbuild.sh load) and video idle;
# the driver's exp_stop_domains parameter and debugfs exp_reset trigger do
# the resets (spec/init.md step 2 per domain).
#   idle    per domain, and for all three: a 30-frame capture whose stop
#           resets no domain leaves the stream's configuration in place;
#           the documented registers (gc573-regs) before and after the
#           reset; every run ends with the spec's full sequence. A control
#           pair (no reset) shows what changes by itself.
#   audio   with an audio capture running and video idle, per domain and
#           then all three: DMA_RUN before and after the reset (kernel
#           log), and whether periods keep coming without a restart
#           (debugfs audio: periods, restarts, stops, a second later).
#   stops   with -s MASK: one audio capture across 3 video captures whose
#           stops reset only MASK; the DMA restarts and frames filled.
# Prints R/K/A/S lines for exp-reset.py.
# Usage: exp-reset.sh [-s MASK]
set -u
dir=$(cd "$(dirname "$0")" && pwd)
W=/tmp/gc573-exp; mkdir -p "$W"
bdf=$(basename "$(readlink -f /sys/bus/pci/drivers/gc573/0000:*)")
res=/sys/bus/pci/devices/$bdf/resource0
dbg=/sys/kernel/debug/gc573-$bdf
par=/sys/module/gc573/parameters
pcm="hw:CARD=$(cat /sys/bus/pci/devices/$bdf/sound/card*/id),DEV=0"
stops=
[ "${1:-}" = -s ] && stops=$2

gcc -O2 -Wall -o $W/gc573-regs "$dir/gc573-regs.c" || exit 2
gcc -O2 -Wall -o $W/gc573-cap "$dir/gc573-cap.c" || exit 2
gcc -O2 -Wall -Wextra -o $W/gc573-aud "$dir/gc573-aud.c" -lasound -lm || exit 2

# spec/regmap.md offsets only (see gc573-regs.c); VIP 0x1000-0x10fc as for
# open question 33
REGS="0x000 0x004 0x008 0x00c 0x010 0x014 0x01c 0x040
 0x100 0x104 0x108 0x120 0x124 0x128 0x200-0x21c 0x2b4-0x2c0
 0x300-0x334 0x500-0x534 0x600-0x634 0x1000-0x10fc
 0x40010 0x40018 0x40020 0x40028 0x40030 0x50000
 0x60010 0x60018 0x60020 0x60028"
snap() { $W/gc573-regs "$res" $REGS | sed "s/^/R $1 /"; }
klast() { dmesg | grep 'exp_reset' | tail -1 | sed 's/^/K /'; }
reset() { echo "$1" > "$dbg/exp_reset" && klast; }
astat() { grep -E '^(periods|regs|order)' "$dbg/audio" | tr '\n' ' '; }
stream() {	# 30 frames; the stop resets ${1:-no} domains
	echo "${1:-0}" > $par/exp_stop_domains
	$W/gc573-cap -d /dev/video0 -L 5 -f YUYV -n 30 > $W/cap.txt 2>&1 ||
		{ echo "S capture failed"; sed 's/^/S   /' $W/cap.txt; }
	echo -1 > $par/exp_stop_domains
}
trap 'echo -1 > $par/exp_stop_domains' EXIT

echo "PARAMS bdf=$bdf pcm=$pcm kernel=$(uname -r)"
if [ -n "$stops" ]; then
	echo "## stops $stops"
	a0=$(astat)
	$W/gc573-aud -D "$pcm" -t 9 -o $W/stops.raw > $W/stops.txt 2>&1 &
	apid=$!
	sleep 1
	for i in 1 2 3; do stream "$stops"; sleep 1; done
	wait $apid
	echo "S before $a0"
	echo "S after  $(astat)"
	grep -E '^(RESULT|XRUN)' $W/stops.txt | sed 's/^/S /'
	exit 0
fi

echo "## control"
stream; snap ctl0; sleep 0.1; snap ctl1; reset 0x301 >/dev/null
for d in 0x001 0x100 0x200 0x301; do
	echo "## idle $d"
	stream; snap "$d-before"; reset "$d"; snap "$d-after"
	[ "$d" = 0x301 ] || reset 0x301 >/dev/null
done

echo "## audio"
$W/gc573-aud -D "$pcm" -t 16 -o $W/aud.raw > $W/aud.txt 2>&1 &
apid=$!
sleep 2
for d in 0x001 0x100 0x200 0x301; do
	a0=$(astat)
	reset "$d"
	sleep 1
	echo "A $d before $a0"
	echo "A $d after  $(astat)"
	sleep 2
done
wait $apid
grep -E '^(RESULT|XRUN)' $W/aud.txt | sed 's/^/A /'
