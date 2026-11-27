#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# gc573-run: named; bare metal only, with the user present (the card's INTx, spec/open-questions.md #43)
# INTx with MSI off (exp_intx=2), no input: the card's pin A, shared
# (spec/pci.md, spec/interrupts.md). By default the driver takes MSI only;
# exp_intx=1 lets it fall back to INTx, which is untested on the card. In
# the gc573-dev VM every INTx bind failed its I2C transfers (-EIO, once
# -ETIMEDOUT), and the line stormed in the guest ("irq 22: nobody
# cared") and on the host ("irq 16: nobody cared", vfio_intx_handler,
# "Disabling IRQ #16"; tests/logs/20261127-064813 and 20261127-075711).
# So this case is not in the default suite (run.sh runs it only by name)
# and SKIPs in a virtual machine: it is for bare-metal validation, with
# the user present. On the development host the card's IRQ 16 is shared
# with both NVMe drives (0000:02:00.0, 0000:04:00.0), which use MSI-X; a
# storm that disabled the line would stop every handler on it. The case
# first loads the driver with its default (MSI) and unloads it, which
# routes the card's INTx; then it lists the PCI devices whose irq is the
# card's (sysfs) and the handlers on it (/proc/interrupts), and SKIPs
# while there are handlers, unless GC573_INTX_SHARED=1.
# Loaded with exp_intx=2, then again after an unbind and a bind:
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
virt=$(systemd-detect-virt --vm 2>/dev/null) || virt=""
if [ -n "$virt" ] || grep -qw hypervisor /proc/cpuinfo; then
	skip "in a virtual machine (${virt:-the hypervisor flag in /proc/cpuinfo}): under VFIO the card's INTx storms the host's line (spec/open-questions.md #43); bare metal only, with the user present"
fi
[ -e /usr/include/alsa/asoundlib.h ] || skip "alsa-lib headers (libasound2-dev) not installed"
pin=$(od -An -tu1 -j61 -N1 "$pdev/config" | tr -d ' ')
[ "${pin:-0}" != 0 ] || skip "the device has no INTx pin (config 0x3d is 0)"
modinfo -p "$GC573_KO" | grep -q '^exp_intx:' ||
	fail "the module has no exp_intx parameter"

# The card's INTx IRQ is the device's irq, which ACPI routes at the
# first PCI enable and keeps after the disable: sysfs irq while MSI is
# off. A load with the default (MSI) and an unload make sure of the
# enable. Config 0x3c, the firmware's line register, need not hold it
# (0xff on the development host).
gc573_load || fail "insmod failed"
gc573_bound || { gc573_unload; fail "not bound with the default (MSI)"; }
gc573_unload || fail "rmmod failed"
line=$(cat "$pdev/irq")
case $line in
'' | 0 | 255) skip "cannot tell the card's INTx IRQ (sysfs irq ${line:-empty} after a load and an unload)" ;;
esac
# The handlers on that IRQ now: a storm on the line disables them all
handlers=$(awk -v n="$line:" '$1 == n {
	for (i = 2; i <= NF && $i ~ /^[0-9]+$/; i++)
		;
	s = ""
	for (j = i + 2; j <= NF; j++)
		s = s (s == "" ? "" : " ") $j
	print s
}' /proc/interrupts)
echo "the card's INTx IRQ: $line; handlers on it now: ${handlers:-none}"
echo "the other PCI devices whose irq is $line (sysfs; a device with MSI on shows its MSI vector instead):"
for d in /sys/bus/pci/devices/*; do
	[ "$d" = "$pdev" ] && continue
	[ "$(cat "$d/irq" 2>/dev/null)" = "$line" ] || continue
	dn=$(readlink "$d/driver" 2>/dev/null)
	dn=${dn##*/}
	nv=$(find "$d/msi_irqs" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
	echo "  ${d##*/} (driver ${dn:-none}, $nv MSI/MSI-X vectors)"
done
if [ -n "$handlers" ] && [ "${GC573_INTX_SHARED:-0}" != 1 ]; then
	skip "IRQ $line has handlers ($handlers): a storm on the card's INTx would disable them; GC573_INTX_SHARED=1 runs the case anyway"
fi
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
gc573_load exp_intx=2 || fail "insmod exp_intx=2 failed"
gc573_bound || { gc573_unload; fail "not bound with exp_intx=2"; }
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
