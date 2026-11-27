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
# gives no RESULT line (both: tests/logs/20261127-094342_6.8.12-gc573dbg_live.log).
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
echo "FAILS $fails"
[ "$fails" = 0 ]
