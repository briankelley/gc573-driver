#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# A stop the card does not confirm (security review of a0adb1d, F4; fix
# review N1, N6, N7), with the test parameter exp_stop_fault, no input
# (free-running). Setting it must taint the kernel (module_param_unsafe).
# The parameter never stops a DMA itself: the driver carries the stop out
# in full, and only once the card confirmed it (INT bit 0 or the reset of
# domain 0, the output off; the audio DMA off) does it count the stop as
# failed (spec/pci.md: bus mastering must never go off while the DMA may
# run). One part per run, GC573_TEST_STOP:
# - streamoff (default): STREAMOFF of gc573-sec stopoff (4 buffers, 120
#   frames) with bit 0 and 1 (no INT bit 0, no domain 0 reset).
# - teardown: an unbind while video and audio stream, with bit 2 (the
#   teardown's check counts the audio DMA as still on).
# - sleep (delta review D4): the streamoff part with bit 4 too, which
#   holds the stop, counted as failed, for 2 s under the video lock
#   before the card is dead; within those 2 s a system sleep with
#   /sys/power/pm_test at "freezer" (the notifiers, then 5 s of frozen
#   tasks; no device sees a suspend). The sleep must start inside the hold
#   (its "suspend entry" line between the hold's and the failed stop's),
#   and the driver must refuse it for the card whose stop failed, not let
#   it through because the stream is off by then. SKIP without pm_test.
# - audio (delta review D6): an audio capture with bit 5 (an audio stop's
#   INT bit 4 counts as missing and its DMA as still on, once the stop was
#   confirmed), stopped (drop) and held open 8 s before the close, which
#   is when the driver syncs the stop (gc573-aud -H). A system sleep in
#   between (pm_test freezer) must be refused for the stop not confirmed,
#   and the close's sync must leave the card dead, 12 KiB kept (the dummy
#   list and the audio buffers). SKIP without pm_test.
# Before anything else is judged, the kernel log must say the stop was
# confirmed and only counted as failed, and BAR0 must read idle (VIP_CTRL
# output and DMA_RUN audio off). If not, the case stops there: no unbind,
# and no reboot or shutdown of the machine (its DMA may run). Then:
# - the driver's line for the failed stop, how much DMA memory it keeps
#   until reboot, debugfs dma_dead 1 and "mem kept" above 0; bus mastering
#   still on (PCI_COMMAND bit 2); the card in dead_cards;
# - streamoff: LOG_STATUS, G_EDID and S_EDID on the same file fail with
#   ENODEV, REQBUFS 0 works, no video or audio stream starts again; the
#   unbind finishes and leaves the device enabled with bus mastering on;
# - teardown: the unbind finishes and both programs end;
# - the module cannot be unloaded, the card cannot be bound again
#   (ENODEV: no driver matches it), and system sleep is refused (with
#   /sys/power/pm_test, as far as its freezer stage);
# - streamoff: a remove and rescan of the device (its DMA confirmed
#   stopped) gives a new device that the driver refuses by its record.
# The card stays dead until reboot: run.sh runs this case last, skips the
# cases after it, and the machine needs a reboot after it (in a VM:
# tools/vms/card-idle.sh first). The kernel log checks of tests/run.sh
# (KASAN, DMA-API debug, lockdep) cover the frees. Allowed: the failures
# this case provokes, and under DMA-API debug its report of the kept
# memory at the unbind.
# gc573-run: last
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

param=/sys/module/$GC573_MOD/parameters/exp_stop_fault
drv=/sys/bus/pci/drivers/$GC573_MOD
pdev=/sys/bus/pci/devices/$GC573_BDF
part=${GC573_TEST_STOP:-streamoff}
case $part in streamoff | teardown | sleep | audio) ;; *) fail "GC573_TEST_STOP: streamoff, teardown, sleep or audio, not '$part'" ;; esac
if [ "$part" = sleep ] || [ "$part" = audio ]; then
	[ -w /sys/power/pm_test ] && grep -qw freeze /sys/power/state ||
		skip "no /sys/power/pm_test or no freeze state"
fi
work=$(mktemp -d)
pids=()

# A module whose exp_stop_fault itself leaves a DMA running (before
# spec/pci.md's rule) would turn bus mastering off under it: refused
modinfo -F parm "$GC573_KO" | grep -q '^exp_stop_fault:.*A DMA stop the card confirmed then counts as failed' ||
	fail "$GC573_KO: its exp_stop_fault is not the confirmed-stop kind: not run"
cap=$(gc573_cap_build "$work") || fail "cannot build gc573-cap"
aud=$(gc573_aud_build "$work") || fail "cannot build gc573-aud"
sec=$(gc573_sec_build "$work") || fail "cannot build gc573-sec"
regs=$(gc573_regs_build "$work") || fail "cannot build gc573-regs"

cleanup() {
	[ -w "$param" ] && echo 0 > "$param"
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	wait 2>/dev/null
	[ -w /sys/power/pm_test ] && echo none > /sys/power/pm_test
	[ -n "$(gc573_dead_cards)" ] || { gc573_loaded && gc573_unload; }
	rm -rf "$work"
}

{
	echo 'exp_stop_fault 0x[0-9a-f]+: the (video|teardown|audio) stop was confirmed'
	echo 'audio stop: no INT bit 4 in [0-9]+ ms'
	echo 'audio stop \(no INT bit 4, the audio DMA still on\) failed: the card keeps bus mastering and gets no driver until reboot'
	echo 'system sleep refused: an audio stop is not confirmed'
	echo 'exp_stop_fault 0x[0-9a-f]+: the video stop counts as failed in [0-9]+ ms, vid.lock held'
	echo 'system sleep refused: the card did not confirm its DMA stopped'
	echo 'video stop \(no INT bit 0, no reset of domain 0\) failed: the card keeps bus mastering and gets no driver until reboot'
	echo 'teardown stop failed: DMA still on'
	echo 'teardown stop failed: the card keeps bus mastering and gets no driver until reboot'
	echo 'HDMI: .*failed: -19'
	echo 'system sleep refused: 1 card\(s\) did not confirm their DMA stopped'
	echo 'WARNING: CPU: [0-9]+ PID: [0-9]+ at kernel/dma/debug\.c:[0-9]+ dma_debug_device_change'
	echo 'DMA-API: Mapped at:'
} >> "$GC573_KMSG_ALLOW"

# $1: pid, $2: seconds; the process has ended
ended() {
	local i
	for i in $(seq $(($2 * 10))); do
		kill -0 "$1" 2>/dev/null || return 0
		sleep 0.1
	done
	return 1
}

# debugfs: DMA memory the driver keeps until reboot, bytes
kept_bytes() { sed -n 's/^mem kept.*: bytes \([0-9]*\);.*/\1/p' "$(gc573_debugfs)"; }

# The kernel log after tag $1: the size of the kept memory, KiB
kept_kib() {
	kmsg_since "$1" | sed -n 's/.*: \([0-9]*\) KiB of DMA memory kept until reboot: .*/\1/p' | head -1
}

# The stop counted as failed was confirmed first, and BAR0 reads idle:
# otherwise stop here, the card as it is (tag $1, $2: which stop)
confirmed_idle() {
	local st
	kmsg_since "$1" | grep -E "exp_stop_fault|$2|keeps bus mastering|kept until reboot" | sed 's/^/  | /'
	if ! kmsg_since "$1" | grep -qE "exp_stop_fault 0x[0-9a-f]+: the $2 stop was confirmed"; then
		echo "!! the $2 stop was not confirmed: the card's DMA may still run. The card is left as it is: no unbind; do not reboot or shut this machine down (spec/pci.md)"
		fail "the $2 stop was not confirmed (a real failure, not the test's)"
	fi
	if ! st=$(gc573_regs_idle "$regs"); then
		echo "!! BAR0 does not read idle ($st): the card's DMA may still run. The card is left as it is: no unbind; do not reboot or shut this machine down (spec/pci.md)"
		fail "the card does not read idle after the stop ($st)"
	fi
	echo "stop confirmed, then counted as failed; BAR0 idle: $st"
}

# What must hold once the card is dead: bus mastering on, recorded, the
# module held, no bind, no sleep
dead_checks() {
	local out
	gc573_master_on || fail "bus mastering off: the driver turned it off after the failed stop"
	gc573_dead_cards | grep -qx "$GC573_BDF" ||
		fail "dead_cards does not list $GC573_BDF: '$(gc573_dead_cards | tr '\n' ' ')'"
	if out=$(rmmod "$GC573_MOD" 2>&1); then
		fail "the module could be unloaded with a card dead"
	fi
	echo "rmmod refused: $out"
	gc573_loaded || fail "the module is gone"
	if gc573_bound; then
		echo "$GC573_BDF" > "$drv/unbind" || fail "unbind failed"
	fi
	if echo "$GC573_BDF" > "$drv/bind" 2> "$work/bind.err"; then
		fail "the card could be bound again"
	fi
	echo "bind refused: $(sed 's/^.*: //' "$work/bind.err")"
	gc573_bound && fail "bound after the refused bind"
	gc573_master_on || fail "bus mastering off after the unbind"
	echo "unbound: PCI enable count $(cat "$pdev/enable"), bus mastering on"
	[ "$(cat "$pdev/enable")" -ge 1 ] || fail "the device was disabled at the unbind (bus mastering went off with it)"
	gc573_sleep_test > "$work/sleep.out"
	case $? in
	0) fail "system sleep went through the freezer stage with a card dead" ;;
	1) echo "system sleep refused: $(cat "$work/sleep.out")" ;;
	*) echo "(no /sys/power/pm_test or no freeze state: sleep not tried)" ;;
	esac
}

# sleep: the stop is held (its line in the kernel log after $tag), or
# gc573-sec ($spid) ended without that
held() {
	local i
	for i in $(seq 600); do
		kmsg_since "$tag" | grep -q 'the video stop counts as failed in [0-9]* ms, vid.lock held' && return 0
		kill -0 "$spid" 2>/dev/null || break
		sleep 0.05
	done
	wait "$spid"
	echo 0 > "$param"
	sed 's/^/stopoff: /' "$work/stopoff.log"
	confirmed_idle "$tag" video
	fail "the stop was not held (a driver without exp_stop_fault bit 4)"
}

# sleep: the system sleep started while the stop was held, and the driver
# refused it for the failed stop ($1: tag, $2: gc573_sleep_test's status)
sleep_during_stop() {
	local t0 t1 t2
	t0=$(kmsg_since "$1" | sed -n 's/^\[ *\([0-9.]*\)\].*: exp_stop_fault 0x[0-9a-f]*: the video stop counts as failed in .*/\1/p' | head -1)
	t1=$(kmsg_since "$1" | sed -n 's/^\[ *\([0-9.]*\)\] PM: suspend entry .*/\1/p' | head -1)
	t2=$(kmsg_since "$1" | sed -n 's/^\[ *\([0-9.]*\)\].*: video stop (no INT bit 0, no reset of domain 0) failed: .*/\1/p' | head -1)
	kmsg_since "$1" | grep -E 'counts as failed in|PM: suspend|system sleep refused|video stop \(no INT' | sed 's/^/  | /'
	[ -n "$t0" ] && [ -n "$t1" ] && [ -n "$t2" ] ||
		fail "a line is missing: the hold '$t0', the sleep's entry '$t1', the failed stop '$t2'"
	awk -v a="$t0" -v b="$t1" -v c="$t2" 'BEGIN { exit !(a < b && b < c) }' ||
		fail "the sleep did not start while the stop was held (hold at $t0 s, entry $t1 s, failed stop $t2 s): not judged"
	echo "the sleep started $(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.3f", b - a }') s into the hold, the failed stop came $(awk -v a="$t0" -v c="$t2" 'BEGIN { printf "%.3f", c - a }') s after the hold began"
	case $2 in
	0) fail "system sleep went through the freezer stage while the stop failed: the driver let it through, the stream being off by then" ;;
	1) echo "system sleep refused: $(cat "$work/sleep1.out")" ;;
	*) fail "pm_test: the sleep could not be tried" ;;
	esac
	kmsg_since "$1" | grep -q 'system sleep refused: the card did not confirm its DMA stopped' ||
		fail "the refusal was not the driver's for the failed stop"
}

gc573_load || fail "insmod failed"
trap cleanup EXIT
[ -w "$param" ] || fail "no exp_stop_fault parameter"
[ -e "/sys/module/$GC573_MOD/parameters/dead_cards" ] || fail "no dead_cards parameter"
[ -z "$(gc573_dead_cards)" ] || fail "a card is dead already: reboot first"
vdev=$(gc573_video_dev) || fail "no video device"
gc573_input_off "$vdev"
gc573_master_on || fail "bus mastering off after the load"

if [ "$part" = streamoff ] || [ "$part" = sleep ]; then
	echo "-- STREAMOFF, confirmed, then counted as without INT bit 0 and domain 0 reset"
	tag=$(kmsg_mark "stop-fault $part")
	if [ "$part" = sleep ]; then val=19; else val=3; fi
	echo "$val" > "$param" || fail "cannot set exp_stop_fault"
	kmsg_since "$tag" | grep -q 'Setting dangerous option exp_stop_fault - tainting kernel' ||
		fail "setting exp_stop_fault did not taint the kernel"
	if [ "$part" = sleep ]; then
		timeout 60 "$sec" stopoff -d "$vdev" -n 120 -b 4 > "$work/stopoff.log" 2>&1 &
		spid=$!
		held
		gc573_sleep_test > "$work/sleep1.out"
		src=$?
		wait "$spid"
		rc=$?
	else
		timeout 60 "$sec" stopoff -d "$vdev" -n 120 -b 4 > "$work/stopoff.log" 2>&1
		rc=$?
	fi
	echo 0 > "$param"
	sed 's/^/stopoff: /' "$work/stopoff.log"
	confirmed_idle "$tag" video
	[ $rc = 0 ] || fail "gc573-sec stopoff: exit $rc"
	[ "$part" = sleep ] && sleep_during_stop "$tag" "$src"
	kmsg_since "$tag" | grep -q 'video stop (no INT bit 0, no reset of domain 0) failed: the card keeps bus mastering and gets no driver until reboot' ||
		fail "no line for the failed stop"
	kib=$(kept_kib "$tag")
	[ -n "$kib" ] && [ "$kib" -gt 0 ] || fail "no line saying how much DMA memory is kept"
	grep -q 'dma_dead 1' "$(gc573_debugfs)" || fail "debugfs does not say dma_dead 1"
	for i in LOG_STATUS G_EDID S_EDID; do
		grep -q "^ioctl $i rc=-1 errno=ENODEV$" "$work/stopoff.log" ||
			fail "$i after the failed stop: '$(grep "^ioctl $i " "$work/stopoff.log")', expected ENODEV"
	done
	grep -q '^ioctl REQBUFS0 rc=0$' "$work/stopoff.log" || fail "REQBUFS 0 after the failed stop failed"
	kb=$(kept_bytes)
	echo "kept: $kib KiB (kernel log); debugfs once the buffers went back: ${kb:-?} bytes"
	[ -n "$kb" ] && [ "$kb" -gt 0 ] || fail "debugfs: nothing kept once the buffers went back"
	if "$cap" -d "$vdev" -n 5 > "$work/cap2.log" 2>&1; then
		fail "a video stream started after the failed stop"
	fi
	echo "video after it: $(grep -m1 -iE 'streamon|error|fail' "$work/cap2.log" || tail -1 "$work/cap2.log")"
	if "$aud" -t 1 > "$work/aud1.log" 2>&1; then
		fail "an audio stream started after the failed stop"
	fi
	echo "audio after it: $(grep -m1 -E "^(read|snd_pcm_open|hw_params|sw_params|start): " "$work/aud1.log" || tail -1 "$work/aud1.log")"
	tag=$(kmsg_mark "stop-fault unbind")
	timeout 30 sh -c "echo $GC573_BDF > $drv/unbind" || fail "unbind did not finish"
	dead_checks
	echo "-- remove and rescan: a new device, refused by the driver's record"
	tag=$(kmsg_mark "stop-fault rescan")
	echo 1 > "$pdev/remove" || fail "remove failed"
	echo 1 > /sys/bus/pci/rescan || fail "rescan failed"
	for i in $(seq 50); do
		kmsg_since "$tag" | grep -q 'did not confirm its DMA stopped earlier in this boot' && break
		sleep 0.1
	done
	kmsg_since "$tag" | grep "$GC573_MOD" | sed 's/^/  | /'
	kmsg_since "$tag" | grep -q 'this card did not confirm its DMA stopped earlier in this boot: not used' ||
		fail "the driver did not refuse the new device by its record"
	[ -e "$pdev" ] || fail "no device after the rescan"
	gc573_bound && fail "the new device is bound"
	gc573_master_on || fail "bus mastering off after the remove and rescan"
	echo "the new device: refused, not bound, bus mastering on"
	echo "the failed stop kept the memory and bus mastering, and the card is left until reboot"
elif [ "$part" = audio ]; then
	echo "-- audio stop, confirmed, then counted as without INT bit 4 and the DMA still on"
	tag=$(kmsg_mark "stop-fault audio")
	echo 32 > "$param" || fail "cannot set exp_stop_fault"
	kmsg_since "$tag" | grep -q 'Setting dangerous option exp_stop_fault - tainting kernel' ||
		fail "setting exp_stop_fault did not taint the kernel"
	"$aud" -t 2 -H 8 > "$work/aud3.log" 2>&1 &
	apid=$!
	pids+=("$apid")
	for i in $(seq 200); do
		grep -q '^DROPPED' "$work/aud3.log" && break
		kill -0 "$apid" 2>/dev/null || break
		sleep 0.05
	done
	grep -q '^DROPPED' "$work/aud3.log" ||
		{ sed 's/^/aud: /' "$work/aud3.log"; fail "gc573-aud did not stop and hold the PCM open"; }
	gc573_sleep_test > "$work/sleep2.out"
	src=$?
	ended "$apid" 30 || fail "gc573-aud did not end"
	wait "$apid"
	rc=$?
	pids=()
	echo 0 > "$param"
	sed 's/^/aud: /' "$work/aud3.log" | tail -3
	confirmed_idle "$tag" audio
	[ $rc = 0 ] || fail "gc573-aud: exit $rc"
	kmsg_since "$tag" | grep -E 'audio stop|system sleep refused|PM: suspend' | sed 's/^/  | /'
	bad=""
	case $src in
	0) bad+="system sleep went through the freezer stage between the audio stop and its sync; " ;;
	1)
		if kmsg_since "$tag" | grep -q 'system sleep refused: an audio stop is not confirmed'; then
			echo "system sleep refused before the sync: $(cat "$work/sleep2.out")"
		else
			bad+="the sleep was refused, but not for the audio stop not confirmed; "
		fi
		;;
	*) bad+="pm_test: the sleep could not be tried; " ;;
	esac
	kmsg_since "$tag" | grep -q 'audio stop (no INT bit 4, the audio DMA still on) failed: the card keeps bus mastering and gets no driver until reboot' ||
		bad+="the close's sync of the stop did not leave the card dead; "
	[ -z "$bad" ] || fail "${bad%; }"
	kib=$(kept_kib "$tag")
	[ "$kib" = 12 ] || fail "kept '$kib' KiB, not 12 (the dummy list and the audio buffers)"
	echo "kept: $kib KiB"
	tag=$(kmsg_mark "stop-fault unbind")
	timeout 30 sh -c "echo $GC573_BDF > $drv/unbind" || fail "unbind did not finish"
	dead_checks
	echo "the audio stop, not confirmed, left the card dead with its memory and bus mastering"
else
	echo "-- unbind while streaming, the teardown's stop confirmed, then counted as the audio DMA still on"
	"$cap" -d "$vdev" -n 100000 > "$work/cap3.log" 2>&1 &
	pids+=($!)
	"$aud" -t 600 > "$work/aud2.log" 2>&1 &
	pids+=($!)
	sleep 2
	for p in "${pids[@]}"; do
		kill -0 "$p" 2>/dev/null || fail "a stream ended before the unbind"
	done
	tag=$(kmsg_mark "stop-fault teardown")
	echo 4 > "$param" || fail "cannot set exp_stop_fault"
	kmsg_since "$tag" | grep -q 'Setting dangerous option exp_stop_fault - tainting kernel' ||
		fail "setting exp_stop_fault did not taint the kernel"
	timeout 60 sh -c "echo $GC573_BDF > $drv/unbind"
	rc=$?
	echo 0 > "$param"
	confirmed_idle "$tag" teardown
	[ $rc = 0 ] || fail "unbind did not finish"
	for p in "${pids[@]}"; do
		ended "$p" 10 || fail "a stream program did not end after the unbind"
	done
	wait 2>/dev/null
	pids=()
	echo "capture: $(tail -1 "$work/cap3.log")"
	echo "audio:   $(tail -1 "$work/aud2.log")"
	kmsg_since "$tag" | grep -q 'teardown stop failed: DMA still on' ||
		fail "the teardown stop did not count the audio DMA as still on"
	kmsg_since "$tag" | grep -q 'teardown stop failed: the card keeps bus mastering and gets no driver until reboot' ||
		fail "no line for the failed teardown stop"
	kib=$(kept_kib "$tag")
	[ -n "$kib" ] && [ "$kib" -gt 0 ] || fail "no line saying how much DMA memory is kept at the teardown"
	echo "kept at the teardown: $kib KiB"
	dead_checks
	echo "the failed teardown stop kept the memory and bus mastering, and the card is left until reboot"
fi
