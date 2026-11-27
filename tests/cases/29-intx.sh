#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# INTx with MSI off (the test parameter exp_intx), no input: the card's
# pin A, shared (spec/pci.md, spec/interrupts.md), which the driver takes
# when it cannot have MSI. 18-fault-inject's binds that fell back to it
# ran with the VM's PCI interrupt routing broken
# (tests/logs/20261127-064813), so the path had no test of its own.
# Loaded with exp_intx=1, then again after an unbind and a bind:
# - the probe took INTx: "using INTx, irq N", N the device's irq in sysfs,
#   no MSI vector, MSI Enable off in config space, the line an IO-APIC one
#   in /proc/interrupts with gc573 on it;
# - the chip IDs on I2C bus 1, whose transfers complete by interrupt (INT
#   bit 11): 0x90 54 49 05 68, 0x58 54 49 63 66;
# - a pattern-checked capture (gc573-cap -p) in YUYV and NV12, 120 frames
#   each, while 5 s of audio run: every 32-byte block overwritten, no
#   sequence gap or error flag, cadence as in 10-video-capture (mean
#   16.6-16.75 ms, every interval 8.4-25 ms); the audio at 48 kHz +- 0.1 %
#   against the clock, no overrun, a period at least every 10 ms (debugfs
#   audio);
# - the line's count rose by at least the frames and the periods, and at
#   most 1 % of its interrupts went unhandled (/proc/irq/N/spurious).
# After the unload no gc573 IRQ, and a load without the parameter takes
# MSI again. "nobody cared" or "Disabling IRQ" in the kernel log fails
# the case (run.sh's KMSG_BAD too). SKIP without an INTx pin or without
# the alsa-lib headers.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

drv=/sys/bus/pci/drivers/$GC573_MOD
pdev=/sys/bus/pci/devices/$GC573_BDF
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
[ -e /usr/include/alsa/asoundlib.h ] || skip "alsa-lib headers (libasound2-dev) not installed"
pin=$(od -An -tu1 -j61 -N1 "$pdev/config" | tr -d ' ')
[ "${pin:-0}" != 0 ] || skip "the device has no INTx pin (config 0x3d is 0)"
modinfo -p "$GC573_KO" | grep -q '^exp_intx:' ||
	fail "the module has no exp_intx parameter"
cap=$(gc573_cap_build "$tmp") || fail "cannot build gc573-cap"
aud=$(gc573_aud_build "$tmp") || fail "cannot build gc573-aud"

bad=0
check() {	# condition result, text
	if [ "$1" = 0 ]; then echo "ok: $2"; else echo "FAILED: $2"; bad=1; fi
}
cfg() { od -An -tu1 -j"$1" -N1 "$pdev/config" | tr -d ' '; }
# MSI Enable, bit 0 of the MSI capability's Message Control ("-": none)
msi_enable() {
	local p i
	p=$(cfg 52)
	for i in $(seq 48); do
		[ "${p:-0}" -ge 64 ] || break
		if [ "$(cfg "$p")" = 5 ]; then
			echo $(($(cfg $((p + 2))) & 1))
			return
		fi
		p=$(cfg $((p + 1)))
	done
	echo -
}
irq_line() { grep -E "^ *$1:" /proc/interrupts | sed 's/  */ /g'; }
# interrupts of line $1 on all CPUs
irq_count() {
	grep -E "^ *$1:" /proc/interrupts | awk '{ n = 0
		for (i = 2; i <= NF && $i ~ /^[0-9]+$/; i++) n += $i
		print n }'
}
unhandled() { sed -n 's/^unhandled //p' "/proc/irq/$1/spurious"; }

# The probe since mark $2 took INTx (step $1); sets irq
mode_check() {
	local log sirq nmsi msi
	log=$(kmsg_since "$2")
	irq=$(sed -n "s/.*$GC573_MOD $GC573_BDF: using INTx, irq \([0-9]*\)$/\1/p" <<< "$log" | tail -1)
	sirq=$(cat "$pdev/irq")
	nmsi=$(find "$pdev/msi_irqs" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
	msi=$(msi_enable)
	check "$([ -n "$irq" ] && [ "$irq" = "$sirq" ] && [ "$nmsi" = 0 ] && [ "$msi" = 0 ]; echo $?)" \
		"$1: the probe took INTx, irq ${irq:-none} (sysfs irq $sirq), $nmsi MSI vectors, MSI Enable $msi"
	check "$(irq_line "${irq:-x}" | grep -q "IO-APIC.* $GC573_MOD\(,\|$\)"; echo $?)" \
		"$1: /proc/interrupts:$(irq_line "${irq:-x}" | cut -d: -f2-)"
	local want ok=0
	for want in "0x90 (IT6805): id 54 49 05 68" "0x58 (splitter): id 54 49 63 66"; do
		grep -q ": I2C bus 1 $want " <<< "$log" && ok=$((ok + 1))
	done
	check "$([ "$ok" = 2 ]; echo $?)" \
		"$1: chip IDs on I2C bus 1 (its transfers complete by interrupt): $(grep -o 'I2C bus 1 0x[0-9a-f]* ([^)]*): id [0-9a-f ]*' <<< "$log" | tr '\n' ';')"
}

# Frames, secs, rate, xruns from a gc573-aud RESULT line in file $1
aud_result() {
	sed -n 's/^RESULT audio frames=\([0-9]*\) secs=\([0-9.]*\) rate=\([0-9.]*\) xruns=\([0-9]*\).*/\1 \2 \3 \4/p' "$1"
}

# A pattern-checked capture in YUYV and NV12 while audio runs, and the
# line's counts (step $1)
stream_check() {
	local dev pcm c0 u0 p0 f rc line apid arc frames secs rate xruns dc du dp
	dev=$(gc573_video_dev) || { check 1 "$1: no video node"; return; }
	pcm=$(gc573_pcm_hw) || { check 1 "$1: no ALSA card"; return; }
	gc573_input_off "$dev"
	c0=$(irq_count "$irq") u0=$(unhandled "$irq") p0=$(gc573_aud_stat periods)
	"$aud" -D "$pcm" -t 5 > "$tmp/aud" 2>&1 &
	apid=$!
	sleep 0.3
	for f in YUYV NV12; do
		"$cap" -d "$dev" -f "$f" -b 4 -n 120 -p > "$tmp/cap" 2>&1
		rc=$?
		grep -E '^(FAIL|RESULT)' "$tmp/cap" | sed -E 's/ ch[0-9]_(bytes|top_word)=[^ ]*//g; s/^/  /'
		line=$(grep "^RESULT capture fmt=$f " "$tmp/cap")
		check "$([ "$rc" = 0 ] && [ -n "$line" ] && awk '{
			for (i = 3; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
			exit !(v["frames"] == 120 && v["seq_gaps"] == 0 && v["err_flags"] == 0 &&
			       v["frames_not_overwritten"] == 0 && v["ivl_ms_mean"] >= 16.6 &&
			       v["ivl_ms_mean"] <= 16.75 && v["min"] >= 8.4 && v["max"] <= 25)
		}' <<< "$line"; echo $?)" "$1: $f, 120 frames, every block overwritten, no gap, cadence"
	done
	wait "$apid"
	arc=$?
	grep -E '^(RESULT|XRUN)' "$tmp/aud" | sed 's/^/  /'
	read -r frames secs rate xruns <<< "$(aud_result "$tmp/aud")"
	dp=$(($(gc573_aud_stat periods) - p0))
	check "$([ "$arc" = 0 ] && [ "${xruns:-1}" = 0 ] && [ "$dp" -ge 495 ] &&
		awk -v r="${rate:-0}" 'BEGIN { exit !(r >= 47952 && r <= 48048) }'; echo $?)" \
		"$1: audio alongside, $frames frames in $secs s at $rate Hz, $xruns overruns, $dp periods"
	dc=$(($(irq_count "$irq") - c0)) du=$(($(unhandled "$irq") - u0))
	check "$([ "$dc" -ge $((240 + dp)) ] && [ $((du * 100)) -le "$dc" ]; echo $?)" \
		"$1: irq $irq: $dc interrupts (at least the 240 frames and $dp periods), $du of them unhandled (at most 1 %)"
}

tag=$(kmsg_mark intx)
gc573_load exp_intx=1 || fail "insmod exp_intx=1 failed"
gc573_bound || { gc573_unload; fail "not bound with exp_intx=1"; }
mode_check "load" "$tag"
stream_check "load"

echo "$GC573_BDF" > "$drv/unbind" || { gc573_unload; fail "unbind failed"; }
check "$(! grep -qw "$GC573_MOD" /proc/interrupts; echo $?)" "unbind: no gc573 IRQ left"
tag2=$(kmsg_mark intx rebind)
echo "$GC573_BDF" > "$drv/bind" || { gc573_unload; fail "bind failed"; }
gc573_bound || { gc573_unload; fail "not bound after the bind"; }
mode_check "rebind" "$tag2"
stream_check "rebind"

gc573_unload || fail "rmmod failed"
check "$(! grep -qw "$GC573_MOD" /proc/interrupts; echo $?)" "unload: no gc573 IRQ left"
storm=$(kmsg_since "$tag" | grep -E 'nobody cared|Disabling IRQ')
check "$([ -z "$storm" ]; echo $?)" "no interrupt storm report${storm:+: $(tr '\n' '|' <<< "$storm")}"

tag3=$(kmsg_mark intx default)
gc573_load || fail "insmod failed"
log=$(kmsg_since "$tag3")
gc573_unload || fail "rmmod failed"
check "$(grep -q "$GC573_MOD $GC573_BDF: using MSI, irq " <<< "$log"; echo $?)" \
	"a load without the parameter takes MSI: $(grep -o 'using [A-Za-z]*, irq [0-9]*' <<< "$log")"

[ "$bad" = 0 ] || fail "see above"
echo "INTx: probe, chip IDs, capture, audio and a rebind OK"
