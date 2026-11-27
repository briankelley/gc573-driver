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
#
# A case whose header has the line "# gc573-run: last" runs after all the
# others: it leaves the card dead until reboot (a stop the card did not
# confirm, src/gc573_core.c gc573_dma_dead(): the memory kept, bus
# mastering on, no driver, the module held, the card in the parameter
# dead_cards). Once a case has left a card dead, the cases after it SKIP
# (run each alone, after a reboot, with its GC573_TEST_* choice), the
# module stays loaded, and run.sh refuses to start until the reboot. A
# reboot of the machine after such a run: in a VM only once
# tools/vms/card-idle.sh says the card is idle. With DMA-API debug run.sh
# also refuses to start while the card's device has DMA mappings and no
# driver. Every DMA-API error is printed while the suite runs
# (dma-api/all_errors), and a case's error_count must rise by exactly the
# errors its log reports and allows.
#
# A case whose header has the line "# gc573-run: named; REASON" runs only
# when named (29-intx: bare metal only); the default suite lists it as
# SKIP with REASON.
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
lockdep_state() {
	if [ -r /proc/lockdep_stats ]; then
		awk '/debug_locks:/ { print $2 }' /proc/lockdep_stats
	else
		echo -
	fi
}
dma_errors() { cat "$DMA_DBG/error_count" 2>/dev/null || echo -; }
debug_state() {
	local dd=-
	[ -r "$DMA_DBG/disabled" ] && dd=$(cat "$DMA_DBG/disabled")
	echo "lockdep debug_locks=$(lockdep_state), DMA-API error_count=$(dma_errors) disabled=$dd"
}

# The DMA-API debug entries of the card's device ("" without DMA-API debug)
dma_entries() {
	[ -r "$DMA_DBG/dump" ] || return 0
	awk -v d="$GC573_BDF" '$2 == d' "$DMA_DBG/dump" | wc -l
}

# A kernel warning's report, from "cut here" to "end trace", is one block.
# When its "WARNING:" line matches a line of the case's allow list that
# itself names "WARNING:", the whole block is allowed (its message, call
# trace and registers); otherwise each of its lines is checked as usual.
# Prints the log with the lines of allowed blocks prefixed "A ", every
# other line "N ". $1: the case's allow list
warn_blocks() {
	awk -v allow="$1" '
		BEGIN {
			while ((getline p < allow) > 0)
				if (p ~ /WARNING:/)
					pat[++np] = p
		}
		function allowed(s,  i) {
			for (i = 1; i <= np; i++)
				if (s ~ pat[i])
					return 1
			return 0
		}
		function flush(ok,  i) {
			for (i = 1; i <= nb; i++)
				print (ok ? "A " : "N ") blk[i]
			nb = 0
			inb = 0
			okb = 0
		}
		index($0, "------------[ cut here ]------------") {
			if (inb)
				flush(0)
			inb = 1
		}
		inb {
			blk[++nb] = $0
			if ($0 ~ /WARNING: CPU: /)
				okb = allowed($0)
			if (index($0, "---[ end trace "))
				flush(okb)
			next
		}
		{ print "N " $0 }
		END { if (inb) flush(0) }'
}

# DMA-API errors in lines $1 (dma-debug's err_printk: "DMA-API: DRIVER
# DEVICE: ..."; a PCI device's name)
dma_error_lines() {
	grep -cE 'DMA-API: [^ ]+ [0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]: ' <<< "$1"
}

# kmemleak's report (stdin), each object's lines prefixed "A " when the
# list $1 (GC573_KMEMLEAK_ALLOW) allows it, then its reason ("W "), else
# "N ". An entry allows an object of its task (comm and pid), of its size,
# whose backtrace has its two functions one after the other (the callee,
# then its caller)
kml_allowed() {
	awk -v allow="$1" '
		BEGIN {
			while ((getline l < allow) > 0) {
				if (split(l, f, "\t") < 6)
					continue
				na++
				ac[na] = f[1]; ap[na] = f[2]; as[na] = f[3]
				a1[na] = f[4]; a2[na] = f[5]; aw[na] = f[6]
			}
		}
		function flush(  i, k, j, ok, why, size, comm, pid, nf, fr, x) {
			if (!nb)
				return
			size = comm = pid = ""
			nf = 0
			if (match(blk[1], /\(size [0-9]+\)/))
				size = substr(blk[1], RSTART + 6, RLENGTH - 7)
			for (i = 2; i <= nb; i++) {
				if (match(blk[i], /comm "[^"]*", pid [0-9]+/)) {
					x = substr(blk[i], RSTART + 6, RLENGTH - 6)
					comm = substr(x, 1, index(x, "\"") - 1)
					pid = x
					sub(/.*, pid /, "", pid)
				} else if (match(blk[i], /^ +[A-Za-z0-9_.]+\+0x[0-9a-f]+\/0x[0-9a-f]+/)) {
					x = substr(blk[i], RSTART, RLENGTH)
					sub(/^ +/, "", x)
					sub(/\+.*/, "", x)
					fr[++nf] = x
				}
			}
			ok = 0
			for (k = 1; k <= na && !ok; k++) {
				if (comm != ac[k] || pid != ap[k] || size != as[k])
					continue
				for (j = 1; j < nf; j++)
					if (fr[j] == a1[k] && fr[j + 1] == a2[k]) {
						ok = 1
						why = aw[k]
						break
					}
			}
			for (i = 1; i <= nb; i++)
				print (ok ? "A " : "N ") blk[i]
			if (ok)
				print "W " why
			nb = 0
		}
		/^unreferenced object / { flush(); inobj = 1 }
		inobj { blk[++nb] = $0; next }
		{ print "N " $0 }
		END { flush() }'
}

named=1
if [ $# -eq 0 ]; then
	named=0
	set -- "$GC573_TESTS"/cases/*.sh
fi
# the cases that keep DMA memory until reboot go last, in their order; a
# case marked "named" runs only when named, not in the default suite
first=() last=() byname=()
for c in "$@"; do
	[ -f "$c" ] || c="$GC573_TESTS/cases/${c%.sh}.sh"
	if [ "$named" = 0 ] && [ -f "$c" ] && grep -q '^# gc573-run: named' "$c"; then
		byname+=("$c")
	elif [ -f "$c" ] && grep -q '^# gc573-run: last' "$c"; then
		last+=("$c")
	else
		first+=("$c")
	fi
done
set -- "${first[@]}" "${last[@]}"

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

dead=$(gc573_dead_cards | tr '\n' ' ')
if [ -n "$dead" ]; then
	echo "run.sh: $GC573_MOD left card(s) ${dead% } dead until reboot (a stop the card did not confirm): reboot first (in a VM: tools/vms/card-idle.sh first)" >&2
	exit 2
fi
if gc573_loaded; then
	echo "$GC573_MOD already loaded: unloading"
	gc573_unload || exit 2
fi
n=$(dma_entries)
if [ -n "$n" ] && [ "$n" != 0 ]; then
	echo "run.sh: the card's device has $n DMA-API debug entries with no driver bound: memory kept by a stop the card did not confirm (tests/cases/22-stop-fault.sh), and every unbind would report it. Reboot first" >&2
	exit 2
fi
# every DMA-API error printed, not only the first of the boot
dma_all=""
if [ -w "$DMA_DBG/all_errors" ]; then
	dma_all=$(cat "$DMA_DBG/all_errors")
	echo 1 > "$DMA_DBG/all_errors"
fi
dma_allowed=0

if kml_available; then
	echo scan=off > "$KML"	# no automatic scans while cases run
	kml_reset		# report leaks older than the suite, forget them
fi
# a case lists the kernel's own leaks a failure it injected leads to, one
# line each: COMM PID SIZE CALLEE CALLER REASON (tab-separated). The
# kmemleak check allows an object of that task, that size, with that
# pair of frames in its backtrace, and says why
GC573_KMEMLEAK_ALLOW=$(mktemp)
export GC573_KMEMLEAK_ALLOW

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

for c in "${byname[@]}"; do
	name=$(basename "$c" .sh)
	echo
	echo "## $name"
	result "$name" SKIP "(not in the default suite: run it by name; $(sed -n 's/^# gc573-run: named;* *//p' "$c" | head -1))"
done

dead_by=""
lockdep_off_in=""
for c in "$@"; do
	name=$(basename "$c" .sh)
	echo
	echo "## $name"
	if [ ! -f "$c" ]; then
		result "$name" FAIL "(no such case)"
		continue
	fi
	if [ -n "$dead_by" ]; then
		result "$name" SKIP "(the card is dead until reboot since $dead_by: run this case alone after a reboot)"
		continue
	fi
	# the case's whole kernel log, also when it outgrows the ring buffer
	GC573_KLOG_FILE=$(mktemp)
	ktail_start "$GC573_KLOG_FILE" ||
		echo "  (no kernel log follower, tests/kmsg-tail.py: the log comes from dmesg)"
	tag=$(kmsg_mark "case $name")
	de0=$(dma_errors)
	ld0=$(lockdep_state)
	start=$(date +%s)
	# a case lists the kernel messages it provokes on purpose (regexes)
	GC573_KMSG_ALLOW=$(mktemp)
	export GC573_KMSG_ALLOW GC573_KLOG_FILE
	bash "$c" 2>&1 | sed 's/^/  /'
	rc=${PIPESTATUS[0]}
	secs=$(($(date +%s) - start))
	dead=$(gc573_dead_cards | tr '\n' ' ')
	if [ -n "$dead" ]; then
		dead_by=$name
		echo "  the case left card(s) ${dead% } dead until reboot: $GC573_MOD stays loaded, and the cases after it SKIP"
	elif gc573_loaded; then
		echo "  case left $GC573_MOD loaded: unloading"
		gc573_unload
	fi

	klog_get "$tag" "$GC573_KLOG_FILE"
	de1=$(dma_errors)
	ld1=$(lockdep_state)
	rm -f "$GC573_KLOG_FILE"
	klog_print
	v=$(echo "$klog" | sed -n 's/.*: FPGA version \([0-9a-f]*\)$/\1/p' | sort -u | tr '\n' ' ')
	fw="$fw $v"
	# the kernel warnings the case allows, whole; then line by line
	marked=$(warn_blocks "$GC573_KMSG_ALLOW" <<< "$klog")
	wexp=$(sed -n 's/^A //p' <<< "$marked")
	bad=$(sed -n 's/^N //p' <<< "$marked" | grep -E "$KMSG_BAD|$KMSG_DRV_BAD")
	expected=$(grep -E "$KMSG_BAD|$KMSG_DRV_BAD" <<< "$wexp" | sed 's/^/(allowed warning) /')
	if [ -n "$bad" ] && [ -s "$GC573_KMSG_ALLOW" ]; then
		expected=$(printf '%s\n%s' "$expected" "$(echo "$bad" | grep -Ef "$GC573_KMSG_ALLOW")" | sed '/^$/d')
		bad=$(echo "$bad" | grep -vEf "$GC573_KMSG_ALLOW")
	fi
	if [ -n "$expected" ]; then
		echo "$expected" | head -n 200 | sed 's/^/  expected: /'
		n=$(grep -c . <<< "$expected")
		[ "$n" -le 200 ] || echo "  expected: ... and $((n - 200)) more"
	fi
	rm -f "$GC573_KMSG_ALLOW"
	if [ -n "$bad" ]; then
		echo "  -- bad kernel messages"
		echo "$bad" | sed 's/^/  ! /'
		rc=$T_FAIL
	fi
	# DMA-API debug: every error the count gained is one the log reports
	# and the case allows
	if [ "$de0" != - ]; then
		n=$(dma_error_lines "$expected")
		if [ $((de1 - de0)) != "$n" ]; then
			echo "  -- DMA-API debug: error_count rose by $((de1 - de0)) ($de0 to $de1), $n of them reported and allowed"
			rc=$T_FAIL
		elif [ "$n" != 0 ]; then
			echo "  DMA-API debug: $n error(s), each reported above and allowed"
		fi
		dma_allowed=$((dma_allowed + n))
	fi
	# lockdep turns itself off at its first report, and at a taint that
	# makes it unreliable (a KASAN report, an oops): say in which case
	if [ "$ld0" = 1 ] && [ "$ld1" = 0 ]; then
		echo "  -- lockdep turned itself off during this case (debug_locks 1 to 0)"
		[ -n "$lockdep_off_in" ] || lockdep_off_in=$name
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
	marked=$(kml_allowed "$GC573_KMEMLEAK_ALLOW" <<< "$leaks")
	na=$(grep -c '^A unreferenced object' <<< "$marked")
	nl=$(grep -c '^N unreferenced object' <<< "$marked")
	if [ "$na" != 0 ]; then
		echo "  allowed, the kernel's own leaks after a failure a case injected ($na objects):"
		sed -n 's/^W /  why: /p; s/^A /  /p' <<< "$marked"
	fi
	if [ "$nl" = 0 ]; then
		echo "  no other new unreferenced objects"
		result kmemleak PASS "$([ "$na" = 0 ] || echo "($na allowed)")"
	else
		sed -n 's/^N /  /p' <<< "$marked"
		result kmemleak FAIL "($nl objects$([ "$na" = 0 ] || echo ", $na more allowed"))"
	fi
else
	echo "  kmemleak not available on this kernel"
	result kmemleak SKIP
fi
rm -f "$GC573_KMEMLEAK_ALLOW"

echo
echo "## debug checkers (whole suite)"
[ -z "$dma_all" ] || echo "$dma_all" > "$DMA_DBG/all_errors"
dbg_after=$(debug_state)
echo "  before: $dbg_before"
echo "  after:  $dbg_after"
de_b=$(sed -n 's/.*error_count=\([^ ]*\) .*/\1/p' <<< "$dbg_before")
de_a=$(sed -n 's/.*error_count=\([^ ]*\) .*/\1/p' <<< "$dbg_after")
[ "$de_b" = - ] || echo "  DMA-API errors reported and allowed in the cases: $dma_allowed"
if [ "$dbg_before" = "lockdep debug_locks=-, DMA-API error_count=- disabled=-" ]; then
	result debug-checkers SKIP "(no lockdep or DMA-API debug)"
else
	# each checker that reported or is off, by name
	why=""
	ld_b=$(sed -n 's/^lockdep debug_locks=\([^,]*\),.*/\1/p' <<< "$dbg_before")
	ld_a=$(sed -n 's/^lockdep debug_locks=\([^,]*\),.*/\1/p' <<< "$dbg_after")
	if [ "$ld_a" != "$ld_b" ] || [ "$ld_a" = 0 ]; then
		why+="lockdep off: debug_locks $ld_b to $ld_a${lockdep_off_in:+, during $lockdep_off_in}; "
	fi
	[[ "$dbg_after" != *"disabled=Y"* ]] || why+="DMA-API debug turned itself off; "
	if [ "$de_b" != - ] && [ $((de_a - de_b)) != "$dma_allowed" ]; then
		why+="DMA-API: error_count rose by $((de_a - de_b)), $dma_allowed of them reported and allowed in the cases; "
	fi
	if [ -z "$why" ]; then
		result debug-checkers PASS
	else
		result debug-checkers FAIL "(${why%; })"
	fi
fi

echo
echo "## summary"
echo "kernel:  $(uname -r)"
echo "card fw: $(echo "$fw" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')"
echo "input:   ${GC573_INPUT:-none}"
printf '%s\n' "${results[@]}"
[ -z "$dead_by" ] ||
	echo "NOTE: $dead_by left the card dead until reboot: reboot before the next run (in a VM: tools/vms/card-idle.sh first)"
echo "SUMMARY pass=$npass fail=$nfail skip=$nskip"
[ "$nfail" = 0 ]
