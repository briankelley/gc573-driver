#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Offline check that tests/live.sh (or GC573_LIVE) keeps its own kernel-log
# helpers: it takes tests/lib.sh's patterns (KMSG_BAD, KMSG_DRV_BAD) with
# lib_kmsg_patterns and never sources lib.sh, whose kmsg_mark and
# kmsg_since (run.sh's: /dev/kmsg as root where the driver runs) would
# replace live.sh's for the rest of a run. The 2-hour Roku soak lost its
# marks that way (tests/logs/20261126-190906_6.8.0-151-generic_live.log).
# Also: setup() puts into the VM every module of this tree that the scripts
# it puts there import, and av_results fails STEP-check when a checker
# gives no RESULT line (both: tests/logs/20261127-094342_6.8.12-gc573dbg_live.log);
# and the remnant step's helpers on made-up gc573-cap output.
# Usage: tests/live-lib-check.sh   (PASS/FAIL lines; exit 1 on a failure)
set -u
here=$(cd "$(dirname "$0")" && pwd)
LIVE=${GC573_LIVE:-$here/live.sh}
fails=0
check() {	# name, condition result, detail
	if [ "$2" = 0 ]; then echo "PASS $1 $3"; else echo "FAIL $1 $3"; fails=$((fails + 1)); fi
}
n=$(grep -cE '^[[:space:]]*(\.|source) .*tests/lib\.sh' "$LIVE")
check live-no-lib-source "$([ "$n" = 0 ]; echo $?)" "($n lines source tests/lib.sh)"
out=$(ROOT=$(cd "$here/.." && pwd) bash -c '
	. <(for f in kmsg_mark lib_kmsg_patterns; do sed -n "/^$f() {/,/^}/p;/^$f() {.*}$/p" "$1"; done)
	declare -F lib_kmsg_patterns > /dev/null || { echo "no lib_kmsg_patterns"; exit 1; }
	lib_kmsg_patterns
	printf "%s\n" "$(declare -f kmsg_mark | grep -c "gc573-live:")" "$KMSG_BAD" "$KMSG_DRV_BAD"
' _ "$LIVE" 2>&1)
mark=$(sed -n 1p <<< "$out")
bad=$(sed -n 2p <<< "$out")
drv=$(sed -n 3p <<< "$out")
check live-own-kmsg-mark "$([ "$mark" = 1 ]; echo $?)" "(kmsg_mark after the patterns: ${mark:-?})"
check live-kmsg-patterns "$(grep -q 'WARNING:' <<< "$bad" && grep -q '^gc573 ' <<< "$drv"; echo $?)" \
	"(KMSG_BAD ${#bad} characters, KMSG_DRV_BAD '${drv:0:40}...')"

# setup() puts into the VM every module of this tree that the Python
# scripts it puts there import (from tests/ or tools/testsrc/): without
# tools/testsrc/scrub.py the recording's recheck in the VM died
# (tests/logs/20261127-094342_6.8.12-gc573dbg_live.log, obsevents)
root=$(cd "$here/.." && pwd)
put=$(sed -n '/^setup() {/,/^}/p' "$LIVE" | grep -oE '\$ROOT/[A-Za-z0-9_./-]+' | sed 's|^\$ROOT/||')
missing=
for f in $put; do
	case $f in *.py) ;; *) continue ;; esac
	for m in $(grep -oE '^[[:space:]]*(from|import) [A-Za-z_][A-Za-z0-9_]*' "$root/$f" | awk '{ print $2 }' | sort -u); do
		have=0 local_mod=
		for d in tests tools/testsrc; do
			[ -e "$root/$d/$m.py" ] || continue
			local_mod+=" $d/$m.py"
			grep -qx "$d/$m.py" <<< "$put" && have=1
		done
		[ -z "$local_mod" ] || [ "$have" = 1 ] || missing+=" $f imports$local_mod"
	done
done
check live-put-imports "$([ -n "$put" ] && [ -z "$missing" ]; echo $?)" \
	"($(wc -w <<< "$put") files put; not put:${missing:- none})"

# av_results fails STEP-check when a checker gives no RESULT line, naming
# its error: the recheck's ModuleNotFoundError failed nothing (094342)
out=$(bash -s "$LIVE" <<'EOF' 2>&1
. <(sed -n '/^av_results() {/,/^}/p' "$1")
result() { echo "R $1 $2 $3"; }
tb=$(printf '%s\n' 'Traceback (most recent call last):' \
	'  File "/tmp/gc573-live/obs-events.py", line 168, in <module>' \
	'    from scrub import scrub  # noqa: E402' \
	"ModuleNotFoundError: No module named 'scrub'")
echo "dead $(av_results x "$tb" | grep '^R x-check')"
echo "empty $(av_results x '' | grep '^R x-check')"
echo "info $(av_results x 'INFO no result here' | grep '^R x-check')"
echo "ok $(av_results x 'RESULT a PASS (fine)' | grep -c '^R x-check')"
EOF
)
dead=$(sed -n 's/^dead //p' <<< "$out")
check live-av-results-dead "$(grep -q "x-check FAIL .*ModuleNotFoundError: No module named 'scrub'" <<< "$dead"; echo $?)" \
	"(a checker's traceback alone: ${dead:-no x-check result})"
check live-av-results-empty "$(grep -q '^empty R x-check FAIL' <<< "$out" &&
	grep -q '^info R x-check FAIL .*INFO no result here' <<< "$out"; echo $?)" \
	"(no output, and output without RESULT: $(grep -E '^(empty|info)' <<< "$out" | tr '\n' ';'))"
check live-av-results-ok "$(grep -qx 'ok 0' <<< "$out"; echo $?)" \
	"(a RESULT line: $(sed -n 's/^ok //p' <<< "$out") x-check results)"

# the remnant step's helpers on made-up gc573-cap output: the frame list
# as runs, the capture's size, the kept frames with their times from
# STREAMON and from the lock line before gc573-cap's STREAMON mark, their
# classification, a capture that kept nothing, and the 720p verdict on
# the kept frames' classes in turn (a black start allowed, as INFO)
out=$(bash -s "$LIVE" <<'EOF' 2>&1
. <(for f in frame_runs cap_size remnant_kept remnant_order; do sed -n "/^$f() {/,/^}/p" "$1"; done)
W=/w
vm() {
	case $1 in
	'sudo dmesg') printf '%s\n' '[  100.000100] gc573 0000:07:00.0: HDMI: locked: 1280x720p, 74250000 Hz' \
		'[  200.500000] gc573 0000:07:00.0: HDMI: locked: 1280x720p, 74250000 Hz' \
		'[  205.000000] gc573-cap: STREAMON /w/b1k' ;;
	*) printf '%s\n' 'FRAME file=/w/b1k-0.YUYV class=uniform word=80108010' \
		'FRAME file=/w/b1k-1.YUYV class=expected' "RESULT a-content PASS (vm: $1)" ;;
	esac
}
result() { echo "R $1 $2 $3"; }
av_results() { echo "AV $1 $(grep '^RESULT' <<< "$2")"; }
cap=$(printf '%s\n' 'FRAME seq=0 ts_ms=5.000 sig=00000000000000aa' \
	'FRAME seq=1 ts_ms=21.700 sig=00000000000000bb' 'FRAME seq=2 ts_ms=38.300 sig=00000000000000bb' \
	'  | stats: irqs 10 frames 3 skipped 1' 'RESULT capture fmt=YUYV 1280x720 frames=3 seq_gaps=0' \
	'KEPT seq=0 ts_ms=5.000 from_streamon_ms=16.700 sig=00000000000000aa file=/w/b1k-0.YUYV' \
	'KEPT seq=1 ts_ms=21.700 from_streamon_ms=33.400 sig=00000000000000bb file=/w/b1k-1.YUYV')
frame_runs "$cap"
echo "size $(cap_size "$cap")"
remnant_kept "$cap" /w/b1k 1280x720 /w/p.png 1280 720 r720
echo "runs $(tr '\n' ';' <<< "$REMNANT_RUNS")"
echo "order1 $(remnant_order "$cap" | tr '\n' ';')"
REMNANT_RUNS='0 146.0 3302.1 expected'
echo "order2 $(remnant_order "$cap" | tr '\n' ';')"
REMNANT_RUNS=$'0 1 - black\n5 2 - expected\n9 3 - black'
echo "order3 $(remnant_order "$cap" | tr '\n' ';')"
REMNANT_RUNS=$'0 1 - other\n5 2 - expected'
echo "order4 $(remnant_order "$cap" | tr '\n' ';')"
REMNANT_RUNS=$'0 1 - black\n5 2 - expected'
echo "order5 $(remnant_order "$cap"$'\nINFO not kept: 3 more frames with a new signature (at most 16 kept)' | tr '\n' ';')"
remnant_kept 'nothing kept' /w/b0k "" - 1920 1080 r0
EOF
)
check live-remnant-runs "$(grep -qF 'frames: seq 0-0 sig=00000000000000aa (1, the first at ts_ms 5.000)' <<< "$out" &&
	grep -qF 'frames: seq 1-2 sig=00000000000000bb (2, the first at ts_ms 21.700)' <<< "$out" &&
	grep -qF 'driver: stats: irqs 10 frames 3 skipped 1' <<< "$out" && grep -qx 'size 1280 720' <<< "$out"; echo $?)" \
	"($(grep -E 'frames:|driver:|^size' <<< "$out" | tr '\n' ';'))"
check live-remnant-kept "$(grep -qF 'kept: seq 0 at 16.7 ms after STREAMON, 4516.7 ms after the lock' <<< "$out" &&
	grep -qF 'remnant-frames.py /w/remnant-a.YUYV 1920 1080 /w/p.png 1280 720 /w/b1k-0.YUYV /w/b1k-1.YUYV' <<< "$out" &&
	grep -qF 'R r0-a-content FAIL (gc573-cap kept no frame)' <<< "$out"; echo $?)" \
	"($(grep -E 'kept:|^AV|^R ' <<< "$out" | cut -c1-90 | tr '\n' ';'))"
check live-remnant-order "$(grep -qxF 'runs 0 16.7 4516.7 black;1 33.4 4533.4 expected;' <<< "$out" &&
	grep -qxF 'order1 OK black expected;INFO black start: 1 frames (seq 0-0), the pattern from seq 1, 33.4 ms after STREAMON, 4533.4 ms after the lock;' <<< "$out" &&
	grep -qxF 'order2 OK expected;' <<< "$out" && grep -qxF 'order3 BAD black expected black;' <<< "$out" &&
	grep -qxF 'order4 BAD other expected;' <<< "$out" &&
	grep -qxF 'order5 BAD black expected, not every change kept;INFO black start: 5 frames (seq 0-4), the pattern from seq 5, 2 ms after STREAMON, - ms after the lock;' <<< "$out"; echo $?)" \
	"($(grep -E '^(runs|order)' <<< "$out" | tr '\n' ' '))"
echo "FAILS $fails"
[ "$fails" = 0 ]
