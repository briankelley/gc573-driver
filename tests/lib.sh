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
# atomic-sleep and DMA-API debug reports, IRQ and list corruption trouble,
# and a freed page written to (page_poison=1: "pagealloc: memory
# corruption"). kmemleak is checked separately by run.sh (its automatic
# scan is paused).
KMSG_BAD='WARNING:|BUG:|Oops|general protection fault|Call Trace:|KASAN|UBSAN'
KMSG_BAD+='|lockdep|possible (circular|recursive) locking|inconsistent lock state'
KMSG_BAD+='|non-static key|DEBUG_LOCKS_WARN_ON|DMA-API|nobody cared|Disabling IRQ'
KMSG_BAD+='|list_(add|del) corruption|refcount_t:|scheduling while atomic'
KMSG_BAD+='|sleeping function called from invalid context|soft lockup|hard LOCKUP'
KMSG_BAD+='|blocked for more than|rcu.*stall|sysfs: cannot create|memory corruption'

# Driver messages that fail any case: the driver's error and warning wording.
# "refused": something tried a bus 0/2 I2C transfer, which nothing should do.
KMSG_DRV_BAD="$GC573_MOD [^ ]+: .*(error|timeout|not ready|unexpected|failed|cannot|MISMATCH|refused)"

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

# Unload the module. A new video node is opened briefly by udev (v4l_id) and
# desktop media daemons (wireplumber), which holds a module reference: wait
# for udev, retry for up to 5 s, then report the last error.
gc573_unload() {
	local i
	udevadm settle 2>/dev/null
	for i in $(seq 50); do
		rmmod "$GC573_MOD" 2>/dev/null && return 0
		gc573_loaded || return 0
		sleep 0.1
	done
	rmmod "$GC573_MOD"
}

# The card's V4L2 capture node (/dev/videoN) while the driver is bound.
gc573_video_dev() {
	local d
	for d in /sys/bus/pci/devices/"$GC573_BDF"/video4linux/video*; do
		[ -e "$d" ] || continue
		echo "/dev/${d##*/}"
		return 0
	done
	return 1
}

# The driver's debugfs state: registers, slots, counters, last completions.
gc573_debugfs() { echo "/sys/kernel/debug/$GC573_MOD-$GC573_BDF/video"; }

# FPGA input measurement registers (0x1004-0x1010), from debugfs. With no
# input, 1010 (frame period) reads 0xffffffff.
gc573_input_regs() { grep '^input:' "$(gc573_debugfs)"; }

# Take the HDMI input away for a case that needs none: clear the EDID
# (VIDIOC_S_EDID, 0 blocks: both HPDs go low and the source stops), then
# wait until QUERY_DV_TIMINGS has failed for 1 s in a row. Unloads and
# fails if the input stays locked for 10 s.
gc573_input_off() {
	local i n=0
	v4l2-ctl -d "$1" --clear-edid=0 >/dev/null 2>&1 ||
		{ gc573_unload; fail "S_EDID with 0 blocks failed"; }
	for i in $(seq 100); do
		if v4l2-ctl -d "$1" --query-dv-timings >/dev/null 2>&1; then
			n=0
		else
			n=$((n + 1))
			[ "$n" -ge 10 ] && return 0
		fi
		sleep 0.1
	done
	gc573_unload
	fail "HDMI input still locked 10 s after the EDID was cleared"
}

# The HDMI front-end's debugfs state (chips, poll statistics, input).
gc573_hdmi_debugfs() { echo "/sys/kernel/debug/$GC573_MOD-$GC573_BDF/hdmi"; }

# One counter from the "hdmi:" line of that file, e.g. gc573_hdmi_stat xfers
gc573_hdmi_stat() {
	sed -n "s/^hdmi:.* $1 \([0-9]*\).*/\1/p" "$(gc573_hdmi_debugfs)"
}

# Build the capture test tool into directory $1; print the binary's path.
gc573_cap_build() {
	gcc -O2 -Wall -Wextra -o "$1/gc573-cap" "$GC573_TESTS/gc573-cap.c" >&2 &&
		echo "$1/gc573-cap"
}

# Build the single-ioctl test tool (tests/gc573-sec.c) into directory $1;
# print the binary's path.
gc573_sec_build() {
	gcc -O2 -Wall -Wextra -o "$1/gc573-sec" "$GC573_TESTS/gc573-sec.c" >&2 &&
		echo "$1/gc573-sec"
}

# Build the BAR0 register reader (tests/gc573-regs.c) into directory $1;
# print the binary's path.
gc573_regs_build() {
	gcc -O2 -Wall -Wextra -o "$1/gc573-regs" "$GC573_TESTS/gc573-regs.c" >&2 &&
		echo "$1/gc573-regs"
}

# PCI_COMMAND bit 2, bus master enable, as the card's config space has it
gc573_master_on() {
	local cmd
	cmd=$(od -An -tx2 -j4 -N2 "/sys/bus/pci/devices/$GC573_BDF/config" | tr -d ' ')
	[ -n "$cmd" ] && [ $((0x$cmd & 4)) != 0 ]
}

# The cards the driver leaves as they are until reboot (parameter
# dead_cards: a DMA stop not confirmed); empty if none or not loaded
gc573_dead_cards() { cat "/sys/module/$GC573_MOD/parameters/dead_cards" 2>/dev/null; }

# The card's DMA engines idle as BAR0 reads, with register reader $1 and
# no driver in between: VIP_CTRL output enable (bit 0) and DMA_RUN audio
# (bit 1) off, neither all-ones. Prints the two values.
gc573_regs_idle() {
	local out run vip
	out=$("$1" "/sys/bus/pci/devices/$GC573_BDF/resource0" 0x008 0x1000) || return 2
	run=$(awk '$1 == "0x00008" { print $2 }' <<< "$out")
	vip=$(awk '$1 == "0x01000" { print $2 }' <<< "$out")
	echo "DMA_RUN $run VIP_CTRL $vip"
	[ -n "$run" ] && [ -n "$vip" ] && [ "$run" != 0xffffffff ] &&
		[ "$vip" != 0xffffffff ] && [ $((run & 2)) = 0 ] && [ $((vip & 1)) = 0 ]
}

# System sleep, as far as the freezer test goes (/sys/power/pm_test
# "freezer": the notifiers run, then the tasks freeze for its delay and
# thaw; no device sees a suspend). Status 0 it went through, 1 refused,
# 77 not available here. Prints the write's error. pm_test is put back.
gc573_sleep_test() {
	local p=/sys/power rc old
	[ -w $p/pm_test ] && grep -qw freeze $p/state 2>/dev/null || return 77
	old=$(sed -n 's/.*\[\([a-z]*\)\].*/\1/p' $p/pm_test)
	echo freezer > $p/pm_test || return 77
	if echo freeze 2>&1 > $p/state; then rc=0; else rc=1; fi
	echo "${old:-none}" > $p/pm_test
	return $rc
}

# Build the audio test tool into directory $1 (alsa-lib headers:
# libasound2-dev); print the binary's path.
gc573_aud_build() {
	gcc -O2 -Wall -Wextra -o "$1/gc573-aud" "$GC573_TESTS/gc573-aud.c" \
		-lasound -lm >&2 && echo "$1/gc573-aud"
}

# The card's ALSA capture PCM (hw:CARD=<id>,DEV=0) while the driver is bound.
gc573_pcm() {
	local c
	for c in /sys/bus/pci/devices/"$GC573_BDF"/sound/card*; do
		[ -e "$c/id" ] || continue
		echo "hw:CARD=$(cat "$c/id"),DEV=0"
		return 0
	done
	return 1
}

# The same PCM by card index (hw:N,0): alsa-lib opens that card's control
# node alone (for a card id it opens every card's before it to compare)
gc573_pcm_hw() {
	local c
	for c in /sys/bus/pci/devices/"$GC573_BDF"/sound/card*; do
		[ -e "$c/number" ] || continue
		echo "hw:$(cat "$c/number"),0"
		return 0
	done
	return 1
}

# One counter from the driver's debugfs "audio" file, e.g. gc573_aud_stat periods
gc573_aud_stat() {
	grep -o "\b$1 [0-9]*" "/sys/kernel/debug/$GC573_MOD-$GC573_BDF/audio" |
		head -1 | cut -d' ' -f2
}
