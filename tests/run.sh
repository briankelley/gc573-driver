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
set -uo pipefail

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

[ "$(id -u)" = 0 ] || { echo "run.sh: run as root" >&2; exit 2; }
[ -f "$GC573_KO" ] || { echo "run.sh: no module at $GC573_KO" >&2; exit 2; }
[ -n "$GC573_BDF" ] || { echo "run.sh: no $GC573_PCI_ID device" >&2; exit 2; }

KML=/sys/kernel/debug/kmemleak
kcfg() { sed -n "s/^CONFIG_$1=//p" "/boot/config-$(uname -r)" 2>/dev/null; }

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

if gc573_loaded; then
	echo "$GC573_MOD already loaded: unloading"
	gc573_unload || exit 2
fi

if [ -w "$KML" ]; then
	echo scan=off > "$KML"	# no automatic scans while cases run
	echo scan > "$KML"	# report leaks older than the suite...
	echo clear > "$KML"	# ...and forget them
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
	tag=$(kmsg_mark "case $name")
	start=$(date +%s)
	bash "$c" 2>&1 | sed 's/^/  /'
	rc=${PIPESTATUS[0]}
	secs=$(($(date +%s) - start))
	if gc573_loaded; then
		echo "  case left $GC573_MOD loaded: unloading"
		gc573_unload
	fi

	klog=$(kmsg_since "$tag")
	echo "  -- kernel log ($(echo "$klog" | grep -c .) lines)"
	echo "$klog" | sed 's/^/  | /'
	v=$(echo "$klog" | sed -n 's/.*: FPGA version \([0-9a-f]*\)$/\1/p' | sort -u | tr '\n' ' ')
	fw="$fw $v"
	bad=$(echo "$klog" | grep -E "$KMSG_BAD|$KMSG_DRV_BAD")
	if [ -n "$bad" ]; then
		echo "  -- bad kernel messages"
		echo "$bad" | sed 's/^/  ! /'
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
if [ -w "$KML" ]; then
	sleep 6			# kmemleak ignores objects younger than 5 s
	echo scan > "$KML"
	leaks=$(cat "$KML")
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
echo "## summary"
echo "kernel:  $(uname -r)"
echo "card fw: $(echo "$fw" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')"
echo "input:   ${GC573_INPUT:-none}"
printf '%s\n' "${results[@]}"
echo "SUMMARY pass=$npass fail=$nfail skip=$nskip"
[ "$nfail" = 0 ]
