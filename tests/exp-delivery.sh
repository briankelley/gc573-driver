#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Experiment, spec/open-questions.md #33 (delivery below 59.94 Hz). PC
# loopback, host side like live.sh. Shows a moving source (ffplay testsrc2
# at RATE fps) full screen on DVI-D-0 (never the primary) at 1920x1080 and
# RATE Hz, then captures N YUYV frames in gc573-dev with a hash of every
# frame and, per completion, a snapshot of the ch0 DMA block (0x300-0x3fc)
# and the VIP block (0x1000-0x10fc) (gc573-cap -F -M). exp-delivery.py
# prints the completion rate, the repeat pattern (runs of identical frames)
# and which registers change, and how that agrees with a new image. The
# driver's exp_rate_fps and exp_rate_bits parameters set RATE_CTRL for the
# stream. Needs ffplay on the host and the module loaded in the VM
# (tools/vmbuild.sh load). Raw output: /tmp/exp-delivery-TAG.txt.
# Usage: tests/exp-delivery.sh RATE [N] [TAG]
rate=${1:?usage: exp-delivery.sh RATE [N] [TAG]} n=${2:-600} tag=${3:-$1}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VM=${VM:-gc573-dev}
VMDIR=${VMDIR:-gc573-driver}
OUT=DVI-D-0
export DISPLAY=${DISPLAY:-:0} XAUTHORITY=${XAUTHORITY:-$HOME/.Xauthority}
raw=/tmp/exp-delivery-$tag.txt

"$ROOT/tools/testsrc/show.sh" --off >/dev/null 2>&1
primary=$(xrandr --query | awk '/ connected primary/{print $1; exit}')
xrandr --output "$OUT" --mode 1920x1080 --rate "$rate" --right-of "$primary" || exit 2
x=$(xrandr --query | sed -n "s/^$OUT connected [^0-9]*[0-9]*x[0-9]*+\([0-9]*\)+.*/\1/p")
setsid ffplay -loglevel error -noborder -an -left "$x" -top 0 -x 1920 -y 1080 \
	-f lavfi -i "testsrc2=size=1920x1080:rate=$rate" </dev/null >/dev/null 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null' EXIT
sleep 6
ssh -n "$VM" "bdf=\$(basename \$(readlink -f /sys/bus/pci/drivers/gc573/0000:*)) &&
	mkdir -p /tmp/gc573-exp &&
	gcc -O2 -Wall -o /tmp/gc573-exp/gc573-cap $VMDIR/tests/gc573-cap.c &&
	sudo /tmp/gc573-exp/gc573-cap -d /dev/video0 -L 10 -f YUYV -b 4 -n $n -F \
		-M /sys/bus/pci/devices/\$bdf/resource0;
	echo PARAMS exp_rate_fps=\$(cat /sys/module/gc573/parameters/exp_rate_fps) \
		exp_rate_bits=\$(cat /sys/module/gc573/parameters/exp_rate_bits)" \
	> "$raw" 2>&1
echo "## exp-delivery $tag: source ${rate} Hz, $n frames"
grep -E '^(LOCK|NOLOCK|FAIL|PARAMS)' "$raw" | cut -c1-200
python3 "$ROOT/tests/exp-delivery.py" "$raw"
