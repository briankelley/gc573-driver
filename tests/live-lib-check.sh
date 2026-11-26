#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Offline check that tests/live.sh (or GC573_LIVE) keeps its own kernel-log
# helpers: it takes tests/lib.sh's patterns (KMSG_BAD, KMSG_DRV_BAD) with
# lib_kmsg_patterns and never sources lib.sh, whose kmsg_mark and
# kmsg_since (run.sh's: /dev/kmsg as root where the driver runs) would
# replace live.sh's for the rest of a run. The 2-hour Roku soak lost its
# marks that way (tests/logs/20261126-190906_6.8.0-151-generic_live.log).
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
echo "FAILS $fails"
[ "$fails" = 0 ]
