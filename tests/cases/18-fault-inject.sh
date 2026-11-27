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
# loader's and the VFS's own allocations stay out, and none with ACPICA
# (drivers/acpi/acpica) there: the filter's one reject range is ACPICA's
# text. An allocation failure in ACPICA can break ACPI's namespace for the
# rest of the boot (tests/logs/20261127-064813: a reference count left
# wrong, a use-after-free at the next _PRT evaluation, and from then on no
# PCI interrupt routing), which then fails what comes after it. kmemleak's
# own allocations count as points: a failure there falls back to its pool,
# and the step is one with no failure in the driver.
# 1. load: finit_module of gc573.ko with the N-th point failed (module init
#    and, where the device has no NUMA node, the probe in the same task):
#    every point up to GC573_FI_LOAD_FULL (60), then every
#    GC573_FI_LOAD_STRIDE-th (10). Loaded with i2c_bus1=1 i2c_bus02=1, so
#    that the I2C adapters' paths count too (the bind and random sweeps
#    use that load).
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
# traces the page allocator prints for a failed vmalloc. Each injected
# failure is printed with its stack (verbose 2, not rate-limited; none for
# an allocation with __GFP_NOWARN). What the stack of a failure in the
# same step explains is allowed too, each line by its own time, at most
# one per such failure:
# - remove_proc_entry()'s warning, from unregister_irq_proc(), for an
#   entry of /proc/irq/N after a failure in register_irq_proc():
#   register_irq_proc() ignores its failures, and unregister_irq_proc()
#   removes every entry, made or not (kernel/irq/proc.c in 6.8), so the
#   warning is the kernel's, not the driver's;
# - the probe's "error -EBUSY: cannot map BAR0" after a failure in
#   __request_region() under the PCI core's region request: a region
#   request whose allocation fails gives -EBUSY, the errno of a region in
#   use (__pci_request_region(), drivers/pci/pci.c in 6.8).
# SKIP without fault injection.
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
fi_set verbose 2			# the notice and the failure's stack
fi_set verbose_ratelimit_interval_ms 0	# every failure's
fi_set task-filter N
fi_set stacktrace-depth 32
fi_set ignore-gfp-wait N	# GFP_KERNEL too: the driver's allocations sleep
echo N > "$FSL/cache-filter"
echo N > "$FPA/ignore-gfp-highmem"
echo 0 > "$FPA/min-order"	# single pages too: vmalloc's, the driver's
echo 30 > /proc/sys/kernel/hung_task_timeout_secs

# Points under module code: from the end of the kernel's text up
etext=$(awk '$3 == "_etext" { print $1; exit }' /proc/kallsyms)
[ -n "$etext" ] && [ $((0x$etext)) != 0 ] || fail "no _etext address in /proc/kallsyms"

# ACPICA's text, the reject range: a point with ACPICA on the stack never
# counts. Its functions by name: the internal ones acpi_<component>_ (ds
# ev ex hw ns ps rs tb ut db dm), and its interface, the functions that
# include/acpi/acpixf.h declares (from the kernel's headers, when
# installed). The range runs from the first of them in the kernel's text
# to the symbol after the last (not their .cold parts, which lie
# elsewhere). A symbol in it not named acpi_* is reported, and the case
# then ends in SKIP with a note: the points under it were not swept
acpica_range() {
	local api=$tmp/acpixf h
	h=/lib/modules/$(uname -r)/build/include/acpi/acpixf.h
	: > "$api"
	if [ -r "$h" ]; then
		tr '\n' ' ' < "$h" | grep -oE '\bacpi_[a-z0-9_]+[[:space:]]*\(' |
			tr -d ' \t(' | sort -u > "$api"
	fi
	LC_ALL=C sort /proc/kallsyms | awk -v etext="$etext" -v api="$api" '
		BEGIN { while ((getline x < api) > 0) pub[x] = 1 }
		function acpica(name) {
			sub(/^__pfx_/, "", name)
			if (name ~ /\.cold$/)
				return 0
			return name ~ /^acpi_(ds|ev|ex|hw|ns|ps|rs|tb|ut|db|dm)_/ || (name in pub)
		}
		NF != 3 || $1 >= etext { next }
		{ n++; a[n] = $1; t[n] = $2; s[n] = $3 }
		END {
			for (i = 1; i <= n; i++)
				if (t[i] ~ /^[tT]$/ && acpica(s[i])) {
					if (!lo)
						lo = i
					hi = i
				}
			if (!lo)
				exit
			for (e = hi + 1; e <= n && a[e] == a[hi]; e++)
				;
			if (e > n)
				exit
			for (i = lo; i < e; i++) {
				x = s[i]
				sub(/^__pfx_/, "", x)
				if (x !~ /^acpi_/)
					other = other " " s[i]
			}
			print a[lo], a[e], e - lo, s[lo], s[hi], s[e] other
		}'
}
r=$(acpica_range)
if [ -n "$r" ]; then
	read -r alo aend acount afirst alast anext aother <<< "$r"
	fi_set reject-start "0x$alo"
	fi_set reject-end "0x$aend"
	echo "ACPICA's text rejected: 0x$alo-0x$aend, $acount symbols ($afirst to $alast; then $anext)"
	if [ -n "$aother" ]; then
		echo "NOTE: in that range, not ACPICA's by name:$aother"
		note+=" the reject range for ACPICA holds other symbols ($aother), whose points were not swept;"
	fi
else
	echo "no ACPICA text found in /proc/kallsyms: nothing rejected"
fi
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
# lost record. The window ends at a mark for step $1 that the call writes
# to the kernel log: once the follower has it, every line logged before
# the call is in the window, and nothing of the next step. Not in a
# subshell: it moves the offset koff
klog_bad() {
	local tag i size win="" len=""
	tag=$(kmsg_mark "18-fault-inject $1")
	for i in $(seq 300); do
		size=$(stat -c %s "$klogf")
		win=$(tail -c +$((koff + 1)) "$klogf" | head -c $((size - koff)))
		# bytes up to the end of the mark's line
		len=$(LC_ALL=C awk -v m="gc573-test: $tag" '
			{ n += length($0) + 1 } index($0, m) { print n; exit }' <<< "$win")
		[ -z "$len" ] || break
		sleep 0.01
	done
	if [ -n "$len" ]; then
		win=$(LC_ALL=C head -c "$len" <<< "$win")
		koff=$((koff + len))
	else
		echo "  (the kernel log follower did not show the mark for $1 within 3 s: the window ends at what it has)"
		koff=$size
	fi
	bad=$(grep -E "$KMSG_BAD|$KMSG_DRV_BAD|debugfs: .*already present|with -EEXIST|^LOST " <<< "$win" |
		grep -vEf "$allow")
	stacks=$(fi_stacks <<< "$win")
	[ -z "$bad" ] || explained "$1" "$win"
	bad=$(head -5 <<< "$bad")
}

# The stacks of the failures injected in the lines on stdin (verbose 2:
# the notice, then dump_stack()): one line per failure, "PID COMM" and the
# reliable frames' functions, innermost first (no "? " frames: stale
# addresses the unwinder only found on the stack)
fi_stacks() {
	awk '
		/\] FAULT_INJECTION: forcing a failure\.$/ { st = 1; next }
		st == 1 && /\] name [a-z_]+, interval [0-9]+, probability / { st = 2; next }
		st == 2 && match($0, /\] CPU: [0-9]+ PID: [0-9]+ Comm: [^ ]+/) {
			split(substr($0, RSTART + 2, RLENGTH - 2), w, " ")
			pid = w[4]
			comm = w[6]
			fr = ""
			st = 3
			next
		}
		st == 3 && /\] +<\/TASK>$/ { print pid, comm fr; st = 0; next }
		st == 3 && match($0, /\] +[A-Za-z0-9_.]+\+0x[0-9a-f]+\/0x[0-9a-f]+/) {
			f = substr($0, RSTART + 1, RLENGTH - 1)
			sub(/^ +/, "", f)
			sub(/\+.*/, "", f)
			fr = fr " " f
			next
		}
		st == 3 { next }
		{ st = 0 }'
}

# Allows kernel log line $2 of step $1 for reason $3: takes it out of bad
# and puts it in run.sh's list as that line alone (its own time)
allow_line() {
	local q
	q=$(sed 's/[[\.*^$+?(){|]/\\&/g' <<< "$2")
	echo "^$q\$" >> "${GC573_KMSG_ALLOW:-/dev/null}"
	bad=$(grep -vxF -- "$2" <<< "$bad")
	echo "  $1: allowed, $3: ${2#*] }"
}

# remove_proc_entry()'s warnings in the lines on stdin that name an entry
# register_irq_proc() makes and whose call trace runs through
# unregister_irq_proc(): "WARNING line<TAB>entry" for each
irq_proc_warnings() {
	awk '
		index($0, "------------[ cut here ]------------") {
			inb = 1
			name = ""
			w = ""
			via = 0
			next
		}
		!inb { next }
		w == "" && match($0, /\] name '\''[a-z_]+'\''$/) {
			name = substr($0, RSTART + 8, RLENGTH - 9)
			next
		}
		/\] WARNING: CPU: [0-9]+ PID: [0-9]+ at fs\/proc\/generic\.c:[0-9]+ remove_proc_entry\+/ {
			w = $0
			next
		}
		/\] +unregister_irq_proc\+0x/ { via = 1; next }
		index($0, "---[ end trace ") {
			if (w != "" && via && name ~ /^(smp_affinity|affinity_hint|smp_affinity_list|node|effective_affinity|effective_affinity_list|spurious)$/)
				print w "\t" name
			inb = 0
		}'
}

# Takes out of bad what the stacks of the failures in step $1's window
# ($2) explain (the header's list), each line at most once per such
# failure, and allows it in run.sh (allow_line)
explained() {
	local n k line name
	n=$(grep -cE ' register_irq_proc( |$)' <<< "$stacks")
	k=0
	while IFS=$'\t' read -r line name; do
		[ "$k" -lt "$n" ] || break
		grep -qxF -- "$line" <<< "$bad" || continue
		allow_line "$1" "$line" "remove_proc_entry('$name') after a failure in register_irq_proc()"
		k=$((k + 1))
	done < <(irq_proc_warnings <<< "$2")
	n=$(awk '/ __request_region( |$)/ && / (__)?pci_request_region( |$)/' <<< "$stacks" | grep -c .)
	k=0
	while read -r line; do
		[ "$k" -lt "$n" ] || break
		allow_line "$1" "$line" "-EBUSY from BAR0's region request after a failure in __request_region()"
		k=$((k + 1))
	done < <(grep -E "\] $GC573_MOD [^ ]+: error -EBUSY: cannot map BAR0$" <<< "$bad")
}
# The kernel's lines of step $1 (klog_bad), each a problem; at the step's
# end, after its unload or unbind, so the lines that undoing it brings are
# its own
klog_step() {
	klog_bad "$1"
	[ -z "$bad" ] || problem "$1: kernel: $(tr '\n' '|' <<< "$bad")"
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

# After a load or bind with a fault (step $1, its result $2): bound and
# working, or nothing left. The kernel log is checked once the step is
# undone (klog_step)
after_fault() {
	local left out
	if gc573_bound; then
		out=$(smoke) || problem "$1: bound, but $out"
	else
		left=$(leftovers)
		[ -z "$left" ] || problem "$1 ($2): left behind: $(tr '\n' ';' <<< "$left")"
	fi
}

errnos=""
count_errno() { errnos+="$(sed -n 's/.* errno=\([A-Z0-9]*\).*/\1/p' "$tmp/out") "; }
errno_summary() { tr ' ' '\n' <<< "$errnos" | sed '/^$/d' | sort | uniq -c | awk '{ printf "%s%s:%s", (NR > 1 ? "," : ""), $2, $1 }'; }

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
	bounded "$fi" load -n "$n" "$GC573_KO" "i2c_bus1=1 i2c_bus02=1"
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
	klog_step "load n=$n"
	[ $((inj % 50)) != 0 ] || echo "  load: $inj faults so far (n=$n)"
	n=$((n < LOAD_FULL ? n + 1 : n + LOAD_STRIDE))
done
gc573_bound || fail "load without a fault (n=$n): not bound"
bad=$(smoke) || fail "load without a fault: $bad"
klog_step "the load without a fault"
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
	klog_step "bind n=$n"
	[ $((inj % 50)) != 0 ] || echo "  bind: $inj faults so far (n=$n)"
	n=$((n < BIND_FULL ? n + 1 : n + BIND_STRIDE))
done
gc573_bound || fail "bind without a fault (n=$n): not bound"
bad=$(smoke) || fail "bind without a fault: $bad"
klog_step "the bind without a fault"
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
	klog_step "sweep $op"
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
	klog_step "random cycle $i"
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
klog_step "the clean bind and unload"
[ "$problems" = 0 ] || fail "$problems problems (above)"
if [ -n "$note" ]; then
	echo "NOTE:$note"
	exit "$T_SKIP"
fi
echo "every injected failure unwound cleanly"
