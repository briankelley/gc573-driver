#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Fault injection, on the debug kernel (tools/devvm/debug-kernel.sh:
# FAILSLAB, FAIL_PAGE_ALLOC, their debugfs files, the stacktrace filter):
# every allocation failure the kernel can inject into the driver's paths
# must unwind cleanly. tests/gc573-fault.c uses fail-nth
# (Documentation/fault-injection/fault-injection.rst): the N-th fault point
# of one task fails, for N = 1, 2, ... until the operation has no N-th
# point. Points count only with module code in the top 32 frames of the
# stack (the stacktrace filter from the kernel text's end up), so the module
# loader's and the VFS's own allocations stay out, and none in kmemleak's
# bookkeeping (a reject range over its allocation path: a failure there
# only falls back to its pool).
# 1. load: finit_module of gc573.ko with the N-th point failed (module init
#    and, where the device has no NUMA node, the probe in the same task):
#    every point up to GC573_FI_LOAD_FULL (60), then every
#    GC573_FI_LOAD_STRIDE-th (10).
# 2. bind: the module loaded, the device unbound; a bind with the N-th point
#    failed, every point (GC573_FI_BIND_FULL, GC573_FI_BIND_STRIDE thin it).
#    After each load or bind: bound (the failure absorbed) and a smoke
#    capture and audio read pass, or nothing of the device is left: no
#    video node, sound card, debugfs directory, I2C adapter "gc573 BDF bus
#    N", IRQ or MSI vector, the PCI device disabled, bus mastering off.
# 3. the ioctls (gc573-fault sweep), the input off: open, REQBUFS, S_FMT,
#    STREAMON, S_EDID, the PCM's open and hw_params. After each injected
#    failure the same step without one passes, a short stream runs, and the
#    driver's buffer memory (debugfs "mem") is back to 0.
# 4. random: GC573_FI_CYCLES (20) cycles of unbind, bind, capture, EDID set
#    and clear, and audio, with GC573_FI_PROB (5) % of the points under the
#    driver's own code failing in any task (the filter on gc573's text);
#    after each unbind nothing left, as in 2.
# Last a clean bind with a capture, audio and the driver's memory at 0.
# Fails on a kernel warning, oops, KASAN/UBSAN or lockdep report, a hung
# task (hung_task_timeout_secs 30 for the case; an operation that does not
# end in 120 s fails at once), a sysfs or debugfs name already present (a
# leftover of an earlier probe), a driver error that is not the injected
# -ENOMEM, or a kernel log that is not complete. Expected and allowed:
# the driver's and the driver core's lines naming -ENOMEM, and the call
# traces the page allocator prints for a failed vmalloc. The injection
# notices are printed (verbose 1, rate-limited), without stack dumps. SKIP
# without fault injection.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

DBG=/sys/kernel/debug
FSL=$DBG/failslab
FPA=$DBG/fail_page_alloc
[ -d "$FSL" ] && [ -d "$FPA" ] ||
	skip "no failslab and fail_page_alloc in debugfs (the debug kernel: CONFIG_FAILSLAB, CONFIG_FAIL_PAGE_ALLOC, CONFIG_FAULT_INJECTION_DEBUG_FS)"
[ -e "$FSL/require-start" ] || skip "no stacktrace filter (CONFIG_FAULT_INJECTION_STACKTRACE_FILTER)"
[ -e "/proc/$$/task/$$/fail-nth" ] || skip "no fail-nth in /proc"
command -v python3 >/dev/null || skip "python3 needed (tests/kmsg-tail.py)"

LOAD_FULL=${GC573_FI_LOAD_FULL:-60}
LOAD_STRIDE=${GC573_FI_LOAD_STRIDE:-10}
BIND_FULL=${GC573_FI_BIND_FULL:-1000000}
BIND_STRIDE=${GC573_FI_BIND_STRIDE:-1}
CYCLES=${GC573_FI_CYCLES:-20}
PROB=${GC573_FI_PROB:-5}
HANG_S=120
drv=/sys/bus/pci/drivers/$GC573_MOD
pdev=/sys/bus/pci/devices/$GC573_BDF
tmp=$(mktemp -d)
fi=$tmp/gc573-fault
problems=0
note=""

# ---- the fault-injection settings, saved and put back on exit ----
FILES="probability interval times space verbose verbose_ratelimit_interval_ms
	verbose_ratelimit_burst task-filter stacktrace-depth require-start
	require-end reject-start reject-end ignore-gfp-wait cache-filter
	ignore-gfp-highmem min-order"
declare -A saved
for f in $FILES; do
	for d in "$FSL" "$FPA"; do
		[ -e "$d/$f" ] && saved[$d/$f]=$(cat "$d/$f")
	done
done
hung0=$(cat /proc/sys/kernel/hung_task_timeout_secs)
ktail=""
restore() {
	local f
	echo 0 > "$FSL/probability"
	echo 0 > "$FPA/probability"
	for f in "${!saved[@]}"; do
		echo "${saved[$f]}" > "$f" 2>/dev/null
	done
	echo "$hung0" > /proc/sys/kernel/hung_task_timeout_secs
	[ -z "$ktail" ] || kill "$ktail" 2>/dev/null
	rm -rf "$tmp"
}
trap restore EXIT

fi_set() {	# file value: on both attributes, where the file exists
	local d
	for d in "$FSL" "$FPA"; do
		[ -e "$d/$1" ] && echo "$2" > "$d/$1"
	done
}
fi_set probability 0
fi_set interval 1
fi_set times 1
fi_set space 0
fi_set verbose 1
fi_set task-filter N
fi_set stacktrace-depth 32
fi_set ignore-gfp-wait N	# GFP_KERNEL too: the driver's allocations sleep
echo N > "$FSL/cache-filter"
echo N > "$FPA/ignore-gfp-highmem"
echo 0 > "$FPA/min-order"	# single pages too: vmalloc's, the driver's
echo 30 > /proc/sys/kernel/hung_task_timeout_secs

# kmemleak's allocation path (mm/kmemleak.c): a range over its functions
# that allocate, so a point there never counts (rejected if on the stack)
# (from the first of these functions to the symbol after the last; all of
# them are in that one file, so the span holds only its code)
kml_range=$(sort /proc/kallsyms | awk '
	{ a[NR] = $1 }
	$3 ~ /^(mem_pool_alloc|__alloc_object|__link_object|__create_object|create_object|kmemleak_alloc|kmemleak_vmalloc|kmemleak_alloc_percpu)$/ {
		if (!lo) lo = $1
		last = NR
	}
	END { if (last && (last + 1) in a) print lo, a[last + 1] }')
if [ -n "$kml_range" ]; then
	read -r klo khi <<< "$kml_range"
	if [ $((0x$khi - 0x$klo)) -gt 0 ] && [ $((0x$khi - 0x$klo)) -lt 262144 ]; then
		fi_set reject-start "0x$klo"
		fi_set reject-end "0x$khi"
		echo "kmemleak's allocation path rejected: 0x$klo-0x$khi"
	else
		echo "kmemleak's allocation path not found as one range ($kml_range): not rejected"
	fi
fi
# Points under module code: from the end of the kernel's text up
etext=$(awk '$3 == "_etext" { print $1; exit }' /proc/kallsyms)
[ -n "$etext" ] && [ $((0x$etext)) != 0 ] || fail "no _etext address in /proc/kallsyms"
filter_modules() {
	fi_set require-start "0x$etext"
	fi_set require-end 0xffffffffffffffff
}
# Points under the driver's own code: its text in /proc/kallsyms
filter_gc573() {
	local r
	r=$(awk '$4 == "[gc573]" && $2 ~ /^[tT]$/ { print $1 }' /proc/kallsyms |
		sort | sed -n '1p;$p' | paste -sd' ')
	[ "${r#* }" != "$r" ] || return 1
	fi_set require-start "0x${r% *}"
	fi_set require-end "$(printf '0x%x' $((0x${r#* } + 4096)))"
}

# ---- tools, the kernel log ----
gcc -O2 -Wall -Wextra -o "$fi" "$GC573_TESTS/gc573-fault.c" -lasound >&2 ||
	fail "cannot build gc573-fault"
cap=$(gc573_cap_build "$tmp") || fail "cannot build gc573-cap"
aud=$(gc573_aud_build "$tmp") || fail "cannot build gc573-aud"
# run.sh follows the case's kernel log (GC573_KLOG_FILE); alone, the case
# does
klogf=${GC573_KLOG_FILE:-}
if [ -z "$klogf" ] || ! grep -q '^# kmsg-tail: following' "$klogf" 2>/dev/null; then
	klogf=$tmp/klog
	python3 "$GC573_TESTS/kmsg-tail.py" "$klogf" &
	ktail=$!
	for _ in $(seq 50); do
		grep -q '^# kmsg-tail: following' "$klogf" 2>/dev/null && break
		sleep 0.1
	done
fi
koff=$(stat -c %s "$klogf")

# What this case provokes on purpose: driver and driver-core lines naming
# the injected -ENOMEM, and the page allocator's report of a failed vmalloc
# (its call trace and frames); they still print
allow=$tmp/allow
cat > "$allow" <<'EOF'
gc573 [^ ]+: .*(ENOMEM|-12([^0-9]|$))
Call Trace:
\] +(\? )?[A-Za-z0-9_.]+\+0x[0-9a-f]+/0x[0-9a-f]+
EOF
cat "$allow" >> "${GC573_KMSG_ALLOW:-/dev/null}"
# Sets bad to the kernel's lines since the last call that fail the case
# here: run.sh's (less the above), a duplicate sysfs or debugfs name, a
# lost record. Not in a subshell: it moves the offset koff
klog_bad() {
	local size
	size=$(stat -c %s "$klogf")
	bad=$(tail -c +$((koff + 1)) "$klogf" | head -c $((size - koff)) |
		grep -E "$KMSG_BAD|$KMSG_DRV_BAD|debugfs: .*already present|with -EEXIST|^LOST " |
		grep -vEf "$allow" | head -5)
	koff=$size
}

problem() {
	problems=$((problems + 1))
	echo "PROBLEM: $*"
	[ "$problems" -lt 25 ] || fail "25 problems: stopping"
}

# run "$@" for at most HANG_S s; its output in $tmp/out; 124 if it hangs
bounded() {
	local pid i
	"$@" > "$tmp/out" 2>&1 &
	pid=$!
	for i in $(seq $((HANG_S * 10))); do
		if ! kill -0 "$pid" 2>/dev/null; then
			wait "$pid"
			return
		fi
		sleep 0.1
	done
	echo "HANG: $* still running after $HANG_S s (pid $pid, left running)"
	ps -o pid,stat,wchan:32,cmd -p "$pid"
	return 124
}

# What a failed probe or an unbind left of the device (nothing: empty)
leftovers() {
	local f x
	for f in "$pdev"/video4linux/video* "$pdev"/sound/card*; do
		[ -e "$f" ] && echo "${f#"$pdev"/}"
	done
	[ -e "$DBG/$GC573_MOD-$GC573_BDF" ] && echo "debugfs $GC573_MOD-$GC573_BDF"
	grep -lF "gc573 $GC573_BDF bus" /sys/bus/i2c/devices/i2c-*/name 2>/dev/null |
		sed 's|/name$||; s|.*/|I2C adapter |'
	grep -w "$GC573_MOD" /proc/interrupts | awk '{ print "IRQ " $1 }'
	x=$(find "$pdev/msi_irqs" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
	[ "$x" = 0 ] || echo "MSI vectors: $x"
	x=$(cat "$pdev/enable")
	[ "$x" = 0 ] || echo "PCI enable count $x"
	x=$(od -An -tu2 -j4 -N2 "$pdev/config" | tr -d ' ')
	[ $((x & 4)) = 0 ] || echo "bus mastering on (COMMAND $x)"
}

# A short capture and audio read on the bound device; once more after the
# input is taken away if the capture fails (a source change while it ran)
smoke() {
	local dev pcm out
	dev=$(gc573_video_dev) || { echo "no video node"; return 1; }
	if ! out=$("$cap" -d "$dev" -f YUYV -b 4 -n 30 -p 2>&1); then
		gc573_input_off "$dev"
		out=$("$cap" -d "$dev" -f YUYV -b 4 -n 30 -p 2>&1) ||
			{ echo "capture: $(grep -E '^(FAIL|RESULT)' <<< "$out" | head -2 | tr '\n' ' ')"; return 1; }
	fi
	pcm=$(gc573_pcm_hw) || { echo "no ALSA card"; return 1; }
	out=$("$aud" -D "$pcm" -t 0.5 2>&1) ||
		{ echo "audio: $(grep -E 'RESULT|rror|fail' <<< "$out" | head -2 | tr '\n' ' ')"; return 1; }
}

# After a load, bind or unbind with a fault (step $1, its result $2):
# bound and working, or nothing left; the kernel log clean
after_fault() {
	local left bad
	if gc573_bound; then
		bad=$(smoke) || problem "$1: bound, but $bad"
	else
		left=$(leftovers)
		[ -z "$left" ] || problem "$1 ($2): left behind: $(tr '\n' ';' <<< "$left")"
	fi
	klog_bad
	[ -z "$bad" ] || problem "$1: kernel: $(tr '\n' '|' <<< "$bad")"
}

errnos=""
count_errno() { errnos+="$(sed -n 's/.* errno=\([A-Z0-9]*\).*/\1/p' "$tmp/out") "; }
errno_summary() { tr ' ' '\n' <<< "$errnos" | sed '/^$/d' | sort | uniq -c | awk '{ printf "%s%s:%s", NR > 1 ? "," : "", $2, $1 }'; }

numa=$(cat "$pdev/numa_node" 2>/dev/null || echo -1)
echo "device $GC573_BDF numa_node $numa"
deps=$(modinfo -F depends "$GC573_KO" | tr , ' ')
if [ -n "$deps" ]; then
	# shellcheck disable=SC2086
	modprobe -a $deps || fail "modprobe $deps"
fi
gc573_loaded && gc573_unload
filter_modules
koff=$(stat -c %s "$klogf")

# ---- 1. load ----
if [ "$numa" != -1 ]; then
	note+=" load and bind sweeps: the probe runs in a worker (numa_node $numa), out of fail-nth's reach;"
	echo "NOTE: numa_node $numa: pci_call_probe runs the probe on a worker, so the load sweep reaches module init only and the bind sweep nothing"
fi
t0=$(date +%s)
n=1 inj=0 nload=0 nbound=0 errnos=""
while :; do
	bounded "$fi" load -n "$n" "$GC573_KO"
	rc=$?
	[ "$rc" = 124 ] && fail "load n=$n hangs"
	[ "$rc" = 3 ] && break		# past the last point: loaded without a fault
	[ "$rc" = 0 ] || { cat "$tmp/out"; fail "gc573-fault load -n $n: exit $rc"; }
	inj=$((inj + 1))
	count_errno
	if gc573_loaded; then
		nload=$((nload + 1))
		gc573_bound && nbound=$((nbound + 1))
		after_fault "load n=$n" "$(cat "$tmp/out")"
		gc573_unload || fail "rmmod after load n=$n failed"
	fi
	[ ! -e "$drv" ] || problem "load n=$n: driver still registered after the module went"
	left=$(leftovers)
	[ -z "$left" ] || problem "load n=$n: left behind after rmmod: $(tr '\n' ';' <<< "$left")"
	[ $((inj % 50)) != 0 ] || echo "  load: $inj faults so far (n=$n)"
	n=$((n < LOAD_FULL ? n + 1 : n + LOAD_STRIDE))
done
gc573_bound || fail "load without a fault (n=$n): not bound"
bad=$(smoke) || fail "load without a fault: $bad"
echo "load: $inj faults (n=1..$((n - 1)), every point to $LOAD_FULL, then every $LOAD_STRIDE-th): module loaded $nload times (bound $nbound), errnos $(errno_summary); $(($(date +%s) - t0)) s"

# ---- 2. bind ----
echo "$GC573_BDF" > "$drv/unbind" || fail "unbind before the bind sweep"
left=$(leftovers)
[ -z "$left" ] || fail "a clean unbind left: $(tr '\n' ';' <<< "$left")"
t0=$(date +%s)
n=1 inj=0 nbound=0 errnos=""
while :; do
	bounded "$fi" bind -n "$n" "$GC573_BDF"
	rc=$?
	[ "$rc" = 124 ] && fail "bind n=$n hangs"
	[ "$rc" = 3 ] && break		# past the last point: bound without a fault
	[ "$rc" = 0 ] || { cat "$tmp/out"; fail "gc573-fault bind -n $n: exit $rc"; }
	inj=$((inj + 1))
	count_errno
	gc573_bound && nbound=$((nbound + 1))
	after_fault "bind n=$n" "$(cat "$tmp/out")"
	if gc573_bound; then
		bounded sh -c "echo $GC573_BDF > $drv/unbind"
		[ $? != 124 ] || fail "unbind after bind n=$n hangs"
		left=$(leftovers)
		[ -z "$left" ] || problem "bind n=$n: the unbind left: $(tr '\n' ';' <<< "$left")"
	fi
	[ $((inj % 50)) != 0 ] || echo "  bind: $inj faults so far (n=$n)"
	n=$((n < BIND_FULL ? n + 1 : n + BIND_STRIDE))
done
gc573_bound || fail "bind without a fault (n=$n): not bound"
bad=$(smoke) || fail "bind without a fault: $bad"
echo "bind: $inj faults (n=1..$((n - 1))), bound anyway $nbound, errnos $(errno_summary); $(($(date +%s) - t0)) s"

# ---- 3. the ioctls ----
dev=$(gc573_video_dev) || fail "no video node"
pcm=$(gc573_pcm_hw) || fail "no ALSA card"
"$fi" edid-save -d "$dev" "$tmp/edid.bin" || fail "cannot save the EDID"
gc573_input_off "$dev"
t0=$(date +%s)
for op in vopen reqbufs s_fmt streamon s_edid pcm_open hw_params; do
	bounded "$fi" sweep "$op" -d "$dev" -D "$pcm" -e "$tmp/edid.bin" \
		-m "$(gc573_debugfs)" -F 1000000 -S 1
	rc=$?
	grep '^FI ' "$tmp/out" | sed 's/^/  /'
	[ "$rc" = 124 ] && fail "sweep $op hangs"
	[ "$rc" = 0 ] || problem "sweep $op: exit $rc ($(grep -v '^FI ' "$tmp/out" | head -3 | tr '\n' ' '))"
	klog_bad
	[ -z "$bad" ] || problem "sweep $op: kernel: $(tr '\n' '|' <<< "$bad")"
done
echo "ioctl sweeps: $(($(date +%s) - t0)) s"

# ---- 4. random ----
filter_gc573 || fail "no gc573 text symbols in /proc/kallsyms"
fi_set times -1
fi_set probability "$PROB"
t0=$(date +%s)
nb=0 nc=0 na=0 ne=0
for i in $(seq "$CYCLES"); do
	if gc573_bound; then
		bounded sh -c "echo $GC573_BDF > $drv/unbind"
		[ $? != 124 ] || fail "random cycle $i: unbind hangs"
		left=$(leftovers)
		[ -z "$left" ] || problem "random cycle $i: the unbind left: $(tr '\n' ';' <<< "$left")"
	fi
	bounded sh -c "echo $GC573_BDF > $drv/bind"
	[ $? != 124 ] || fail "random cycle $i: bind hangs"
	if ! gc573_bound; then
		left=$(leftovers)
		[ -z "$left" ] || problem "random cycle $i: the failed bind left: $(tr '\n' ';' <<< "$left")"
	elif dev=$(gc573_video_dev); then
		nb=$((nb + 1))
		bounded "$cap" -d "$dev" -f NV12 -b 4 -n 60 -p
		case $? in
		124) fail "random cycle $i: capture hangs" ;;
		0) nc=$((nc + 1)) ;;
		esac
		bounded "$fi" edid-set -d "$dev" "$tmp/edid.bin"
		[ $? != 124 ] || fail "random cycle $i: S_EDID hangs"
		bounded "$fi" edid-set -d "$dev" none
		case $? in
		124) fail "random cycle $i: S_EDID 0 blocks hangs" ;;
		0) ne=$((ne + 1)) ;;
		esac
		if pcm=$(gc573_pcm_hw); then
			bounded "$aud" -D "$pcm" -t 0.5
			case $? in
			124) fail "random cycle $i: audio hangs" ;;
			0) na=$((na + 1)) ;;
			esac
		fi
	fi
	klog_bad
	[ -z "$bad" ] || problem "random cycle $i: kernel: $(tr '\n' '|' <<< "$bad")"
done
fi_set probability 0
echo "random: $CYCLES cycles at $PROB %: bound $nb, captures through $nc, EDID set and cleared $ne, audio $na (failures there are the injection's); $(($(date +%s) - t0)) s"

# ---- last: clean ----
filter_modules
if gc573_bound; then
	echo "$GC573_BDF" > "$drv/unbind" || fail "the last unbind failed"
fi
left=$(leftovers)
[ -z "$left" ] || problem "after the random cycles: left behind: $(tr '\n' ';' <<< "$left")"
echo "$GC573_BDF" > "$drv/bind" || fail "a clean bind failed"
gc573_bound || fail "not bound after a clean bind"
bad=$(smoke) || fail "after the faults: $bad"
mem=$(sed -n 's/^mem (live, all cards): //p' "$(gc573_debugfs)")
[ "$mem" = "bufs 0 pages 0 vmaps 0 dlists 0 dl_bytes 0" ] ||
	problem "driver memory not back to 0: ${mem:-no mem line}"
echo "after the faults: bind, capture and audio OK; driver memory: $mem"
gc573_unload || fail "rmmod failed"
sleep 0.5
klog_bad
[ -z "$bad" ] || problem "kernel: $(tr '\n' '|' <<< "$bad")"
[ "$problems" = 0 ] || fail "$problems problems (above)"
if [ -n "$note" ]; then
	echo "NOTE:$note"
	exit "$T_SKIP"
fi
echo "every injected failure unwound cleanly"
