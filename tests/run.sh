#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# GC573 regression suite. Runs the cases in tests/cases as root on the machine
# that holds the card (the gc573-dev VM during bring-up), checks the kernel log
# each case produced, and runs one kmemleak scan over the whole suite. Prints a
# RESULT line per case and a SUMMARY; exits 1 if any case fails.
# tools/vmbuild.sh test runs it in the VM and saves the log in tests/logs/.
#
# Usage: sudo tests/run.sh [CASE...]   CASE: file in tests/cases, .sh optional
# Env:   GC573_KO     module under test (default: gc573.ko in the repo root)
#        GC573_INPUT  HDMI input source and mode, for the log (default: none)
#        GC573_REV    source revision, for the log
#        GC573_KLOG_LINES  a case kernel log longer than this (default 1000)
#                     is printed as its first and last 400 lines, and the
#                     lines between that match KMSG_BAD or KMSG_DRV_BAD
#                     (checked in full either way)
#
# Each case's kernel log is followed while it runs (tests/kmsg-tail.py into
# a file, exported to the case as GC573_KLOG_FILE): complete even when the
# case writes more than dmesg's ring buffer holds. Without python3 it comes
# from dmesg after the case. A log that is not complete (the ring overran
# the follower, or overwrote the case's start in dmesg) fails the case.
set -uo pipefail

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

[ "$(id -u)" = 0 ] || { echo "run.sh: run as root" >&2; exit 2; }
[ -f "$GC573_KO" ] || { echo "run.sh: no module at $GC573_KO" >&2; exit 2; }
[ -n "$GC573_BDF" ] || { echo "run.sh: no $GC573_PCI_ID device" >&2; exit 2; }

DMA_DBG=/sys/kernel/debug/dma-api
kcfg() { sed -n "s/^CONFIG_$1=//p" "/boot/config-$(uname -r)" 2>/dev/null; }
KLOG_LINES=${GC573_KLOG_LINES:-1000}
KLOG_KEEP=400

# Follow the kernel log into file $1 (tests/kmsg-tail.py): sets ktail to
# the follower's pid once it reads at the end of the log, "" if it cannot
ktail=""
ktail_start() {
	local i
	python3 "$GC573_TESTS/kmsg-tail.py" "$1" 2>/dev/null &
	ktail=$!
	for i in $(seq 50); do
		grep -q '^# kmsg-tail: following' "$1" 2>/dev/null && return 0
		kill -0 "$ktail" 2>/dev/null || break
		sleep 0.1
	done
	kill "$ktail" 2>/dev/null
	wait "$ktail" 2>/dev/null
	ktail=""
	return 1
}

# The kernel log of the case marked $1 into klog; klog_incomplete says why
# it is not complete ("" when it is). With a follower (file $2): the lines
# between the case's mark and an end mark written now, once the follower
# has it. Otherwise dmesg's, after the mark.
klog_get() {
	local etag i
	klog_incomplete=""
	if [ -n "$ktail" ]; then
		etag=$(kmsg_mark "end of $name")
		for i in $(seq 50); do
			grep -qF "gc573-test: $etag" "$2" && break
			sleep 0.1
		done
		kill "$ktail" 2>/dev/null
		wait "$ktail" 2>/dev/null
		ktail=""
		grep -qF "gc573-test: $etag" "$2" ||
			klog_incomplete="the follower did not get the end mark"
		if grep -qF "gc573-test: $1" "$2"; then
			klog=$(awk -v s="gc573-test: $1" -v e="gc573-test: $etag" '
				index($0, e) { exit } f; index($0, s) { f = 1 }' "$2")
		else
			klog=$(awk -v e="gc573-test: $etag" 'index($0, e) { exit }
				NR > 1' "$2")
			klog_incomplete="no start mark in the follower's file"
		fi
		i=$(grep -c '^LOST ' <<< "$klog")
		[ "$i" = 0 ] ||
			klog_incomplete="the ring buffer overran the follower ($i LOST lines)"
	else
		klog=$(kmsg_since "$1")
		dmesg | grep -qF "gc573-test: $1" ||
			klog_incomplete="dmesg's ring buffer overwrote the case's start"
	fi
}

# Print the case log: whole up to KLOG_LINES lines, else the first and
# last KLOG_KEEP lines and, between them, the lines a check looks at
klog_print() {
	local n
	n=$(grep -c . <<< "$klog")
	echo "  -- kernel log ($n lines)"
	if [ "$n" -le "$KLOG_LINES" ]; then
		[ "$n" = 0 ] || echo "$klog" | sed 's/^/  | /'
		return
	fi
	echo "$klog" | head -n "$KLOG_KEEP" | sed 's/^/  | /'
	echo "  | ... lines $((KLOG_KEEP + 1))-$((n - KLOG_KEEP)) not shown (all checked); among them these match KMSG_BAD or KMSG_DRV_BAD, or say LOST:"
	echo "$klog" | sed -n "$((KLOG_KEEP + 1)),$((n - KLOG_KEEP))p" |
		grep -nE "$KMSG_BAD|$KMSG_DRV_BAD|^LOST " |
		awk -v o="$KLOG_KEEP" -v max=200 '{
			i = index($0, ":"); k++
			if (k <= max) printf "  | %d: %s\n", substr($0, 1, i - 1) + o, substr($0, i + 1)
		} END {
			if (k > max) printf "  | ... and %d more of them\n", k - max
			if (!k) print "  | (none)"
		}'
	echo "  | ..."
	echo "$klog" | tail -n "$KLOG_KEEP" | sed 's/^/  | /'
}

# Debug checkers' state: lockdep turns itself off after its first report,
# DMA-API debug counts errors. "-" = not in this kernel.
debug_state() {
	local dl=- de=- dd=-
	[ -r /proc/lockdep_stats ] && dl=$(awk '/debug_locks:/ { print $2 }' /proc/lockdep_stats)
	[ -r "$DMA_DBG/error_count" ] && de=$(cat "$DMA_DBG/error_count")
	[ -r "$DMA_DBG/disabled" ] && dd=$(cat "$DMA_DBG/disabled")
	echo "lockdep debug_locks=$dl, DMA-API error_count=$de disabled=$dd"
}

[ $# -gt 0 ] || set -- "$GC573_TESTS"/cases/*.sh

echo "# GC573 regression suite"
echo "date:    $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "host:    $(hostname)"
echo "kernel:  $(uname -r) $(uname -v)"
echo "debug:   KASAN=$(kcfg KASAN) PROVE_LOCKING=$(kcfg PROVE_LOCKING)" \
	"DEBUG_KMEMLEAK=$(kcfg DEBUG_KMEMLEAK) DMA_API_DEBUG=$(kcfg DMA_API_DEBUG)" \
	"DEBUG_ATOMIC_SLEEP=$(kcfg DEBUG_ATOMIC_SLEEP)"
echo "card:    $(lspci -nn -s "$GC573_BDF")"
echo "         subsystem $(lspci -n -v -s "$GC573_BDF" | sed -n 's/.*Subsystem: //p')"
echo "module:  $GC573_KO srcversion $(modinfo -F srcversion "$GC573_KO")"
echo "rev:     ${GC573_REV:-unknown}"
echo "input:   ${GC573_INPUT:-none}"
dbg_before=$(debug_state)
echo "checks:  $dbg_before"

if gc573_loaded; then
	echo "$GC573_MOD already loaded: unloading"
	gc573_unload || exit 2
fi

if kml_available; then
	echo scan=off > "$KML"	# no automatic scans while cases run
	kml_reset		# report leaks older than the suite, forget them
fi

npass=0
nfail=0
nskip=0
results=()
fw=""

result() {
	local line
	line=$(printf 'RESULT %-20s %-4s %s' "$1" "$2" "${3:-}")
	echo "$line"
	results+=("$line")
	case $2 in
	PASS) npass=$((npass + 1)) ;;
	SKIP) nskip=$((nskip + 1)) ;;
	*) nfail=$((nfail + 1)) ;;
	esac
}

for c in "$@"; do
	[ -f "$c" ] || c="$GC573_TESTS/cases/${c%.sh}.sh"
	name=$(basename "$c" .sh)
	echo
	echo "## $name"
	if [ ! -f "$c" ]; then
		result "$name" FAIL "(no such case)"
		continue
	fi
	# the case's whole kernel log, also when it outgrows the ring buffer
	GC573_KLOG_FILE=$(mktemp)
	ktail_start "$GC573_KLOG_FILE" ||
		echo "  (no kernel log follower, tests/kmsg-tail.py: the log comes from dmesg)"
	tag=$(kmsg_mark "case $name")
	start=$(date +%s)
	# a case lists the kernel messages it provokes on purpose (regexes)
	GC573_KMSG_ALLOW=$(mktemp)
	export GC573_KMSG_ALLOW GC573_KLOG_FILE
	bash "$c" 2>&1 | sed 's/^/  /'
	rc=${PIPESTATUS[0]}
	secs=$(($(date +%s) - start))
	if gc573_loaded; then
		echo "  case left $GC573_MOD loaded: unloading"
		gc573_unload
	fi

	klog_get "$tag" "$GC573_KLOG_FILE"
	rm -f "$GC573_KLOG_FILE"
	klog_print
	v=$(echo "$klog" | sed -n 's/.*: FPGA version \([0-9a-f]*\)$/\1/p' | sort -u | tr '\n' ' ')
	fw="$fw $v"
	bad=$(echo "$klog" | grep -E "$KMSG_BAD|$KMSG_DRV_BAD")
	if [ -n "$bad" ] && [ -s "$GC573_KMSG_ALLOW" ]; then
		expected=$(echo "$bad" | grep -Ef "$GC573_KMSG_ALLOW")
		if [ -n "$expected" ]; then
			echo "$expected" | head -n 200 | sed 's/^/  expected: /'
			n=$(grep -c . <<< "$expected")
			[ "$n" -le 200 ] || echo "  expected: ... and $((n - 200)) more"
		fi
		bad=$(echo "$bad" | grep -vEf "$GC573_KMSG_ALLOW")
	fi
	rm -f "$GC573_KMSG_ALLOW"
	if [ -n "$bad" ]; then
		echo "  -- bad kernel messages"
		echo "$bad" | sed 's/^/  ! /'
		rc=$T_FAIL
	fi
	if [ -n "$klog_incomplete" ]; then
		echo "  -- kernel log INCOMPLETE: $klog_incomplete; the check covered only what is above"
		rc=$T_FAIL
	fi
	case $rc in
	"$T_PASS") result "$name" PASS "(${secs}s)" ;;
	"$T_SKIP") result "$name" SKIP "(${secs}s)" ;;
	*) result "$name" FAIL "(${secs}s, exit $rc)" ;;
	esac
done

echo
echo "## kmemleak (whole suite)"
if kml_available; then
	leaks=$(kml_report)
	echo scan=on > "$KML"
	if [ -z "$leaks" ]; then
		echo "  no new unreferenced objects"
		result kmemleak PASS
	else
		echo "$leaks" | sed 's/^/  /'
		result kmemleak FAIL "($(echo "$leaks" | grep -c 'unreferenced object') objects)"
	fi
else
	echo "  kmemleak not available on this kernel"
	result kmemleak SKIP
fi

echo
echo "## debug checkers (whole suite)"
dbg_after=$(debug_state)
echo "  before: $dbg_before"
echo "  after:  $dbg_after"
if [ "$dbg_before" = "lockdep debug_locks=-, DMA-API error_count=- disabled=-" ]; then
	result debug-checkers SKIP "(no lockdep or DMA-API debug)"
elif [ "$dbg_after" = "$dbg_before" ] && [[ "$dbg_after" != *"debug_locks=0"* ]] &&
     [[ "$dbg_after" != *"disabled=Y"* ]]; then
	result debug-checkers PASS
else
	result debug-checkers FAIL "(a checker reported or is off)"
fi

echo
echo "## summary"
echo "kernel:  $(uname -r)"
echo "card fw: $(echo "$fw" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')"
echo "input:   ${GC573_INPUT:-none}"
printf '%s\n' "${results[@]}"
echo "SUMMARY pass=$npass fail=$nfail skip=$nskip"
[ "$nfail" = 0 ]
