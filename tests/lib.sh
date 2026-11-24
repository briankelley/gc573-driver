# SPDX-License-Identifier: GPL-2.0
# Helpers shared by tests/run.sh and tests/cases/*.sh. Sourced by bash, run as root.

GC573_TESTS=${GC573_TESTS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
GC573_KO=${GC573_KO:-$(cd "$GC573_TESTS/.." && pwd)/gc573.ko}
GC573_MOD=gc573
GC573_PCI_ID=1461:0054
GC573_BDF=${GC573_BDF:-$(lspci -D -n -d "$GC573_PCI_ID" | awk 'NR == 1 { print $1 }')}

# Case exit codes (automake convention).
T_PASS=0
T_FAIL=1
T_SKIP=77

# Kernel messages that fail any case: warnings and oopses, sanitizer, lockdep,
# atomic-sleep and DMA-API debug reports, IRQ and list corruption trouble.
# kmemleak is checked separately by run.sh (its automatic scan is paused).
KMSG_BAD='WARNING:|BUG:|Oops|general protection fault|Call Trace:|KASAN|UBSAN'
KMSG_BAD+='|lockdep|possible (circular|recursive) locking|inconsistent lock state'
KMSG_BAD+='|non-static key|DEBUG_LOCKS_WARN_ON|DMA-API|nobody cared|Disabling IRQ'
KMSG_BAD+='|list_(add|del) corruption|refcount_t:|scheduling while atomic'
KMSG_BAD+='|sleeping function called from invalid context|soft lockup|hard LOCKUP'
KMSG_BAD+='|blocked for more than|rcu.*stall|sysfs: cannot create'

# Driver messages that fail any case: the driver's error and warning wording.
# "refused": something tried a bus 0/2 I2C transfer, which nothing should do.
KMSG_DRV_BAD="$GC573_MOD [^ ]+: .*(error|timeout|not ready|unexpected|failed|MISMATCH|refused)"

# kmemleak reports an object only after two consecutive scans found it
# unreferenced with unchanged contents: a scan that sees a changed checksum
# (every new object starts at 0) greys the object instead (mm/kmemleak.c,
# update_checksum). So every check scans twice; one scan reports nothing new.
KML=/sys/kernel/debug/kmemleak
kml_available() { [ -w "$KML" ]; }
# Report what leaked so far, then forget it.
kml_reset() {
	echo scan > "$KML"
	echo scan > "$KML"
	echo clear > "$KML"
}
# Print the leaks since the last kml_reset. Objects younger than 5 s are
# skipped by kmemleak, hence the wait.
kml_report() {
	sleep 6
	echo scan > "$KML"
	echo scan > "$KML"
	cat "$KML"
}

fail() { echo "FAIL: $*"; exit "$T_FAIL"; }
skip() { echo "SKIP: $*"; exit "$T_SKIP"; }

# Write a unique marker to the kernel log; print the tag to pass to kmsg_since.
kmsg_mark() {
	local tag
	tag="$(date +%s%N)-$RANDOM $*"
	echo "gc573-test: $tag" > /dev/kmsg
	echo "$tag"
}

# Kernel log written after the marker for TAG.
kmsg_since() {
	dmesg | awk -v m="gc573-test: $1" 'f; index($0, m) { f = 1 }'
}

gc573_loaded() { grep -q "^$GC573_MOD " /proc/modules; }
gc573_bound() { [ -e "/sys/bus/pci/drivers/$GC573_MOD/$GC573_BDF" ]; }

# Load the module under test (plus the in-tree modules it depends on).
gc573_load() {
	local deps
	deps=$(modinfo -F depends "$GC573_KO" | tr , ' ')
	if [ -n "$deps" ]; then
		# shellcheck disable=SC2086
		modprobe -a $deps || return
	fi
	insmod "$GC573_KO" "$@"
}

gc573_unload() { rmmod "$GC573_MOD"; }
