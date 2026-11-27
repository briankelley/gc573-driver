#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Unbind while programs hold the card's ALSA nodes (security review of
# a0adb1d, F6): two processes keep the control node and the capture PCM
# open (no stream), as any seat user can. The unbind must finish within
# 20 s, not wait for them: the card is disconnected and goes with its
# last file. The holders stay alive with their files open; once they
# close, nothing may hold gc573 and it must unload. Before the fix the
# unbind blocks, uninterruptibly, until the holders close: the case then
# fails and closes them itself, which lets the unbind finish.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

drv=/sys/bus/pci/drivers/$GC573_MOD
dev=/sys/bus/pci/devices/$GC573_BDF
holders=()

# $1: pid, $2: seconds; the process has ended
ended() {
	local i
	for i in $(seq $(($2 * 10))); do
		kill -0 "$1" 2>/dev/null || return 0
		sleep 0.1
	done
	return 1
}

cleanup() {
	for p in "${holders[@]}"; do kill "$p" 2>/dev/null; done
	wait 2>/dev/null
	gc573_loaded && gc573_unload
}

gc573_load || fail "insmod failed"
trap cleanup EXIT
c=$(ls -d "$dev"/sound/card[0-9]* 2>/dev/null | head -1)
[ -n "$c" ] || fail "no ALSA card"
n=${c##*card}
ctl=/dev/snd/controlC$n
pcm=/dev/snd/pcmC${n}D0c
[ -c "$ctl" ] && [ -c "$pcm" ] || fail "no $ctl or $pcm"

sleep 600 < "$ctl" &
holders+=($!)
sleep 600 < "$pcm" &
holders+=($!)
sleep 0.5
for p in "${holders[@]}"; do
	echo "holder $p: $(readlink "/proc/$p/fd/0")"
done

start=$(date +%s%N)
( echo "$GC573_BDF" > "$drv/unbind" ) &
u=$!
bad=0
if ended "$u" 20; then
	echo "unbind finished in $((($(date +%s%N) - start) / 1000000)) ms with the ALSA nodes held"
else
	echo "BAD:  the unbind is blocked while the card's ALSA nodes are held"
	bad=1
fi
for p in "${holders[@]}"; do
	kill -0 "$p" 2>/dev/null ||
		{ echo "BAD:  holder $p did not survive the unbind"; bad=1; }
done
[ "$bad" = 1 ] || echo "holders still running, module references: $(cat "/sys/module/$GC573_MOD/refcnt")"
[ -e "$dev/driver" ] && [ "$bad" = 0 ] && { echo "BAD:  the device is still bound"; bad=1; }

for p in "${holders[@]}"; do kill "$p" 2>/dev/null; done
wait "${holders[@]}" 2>/dev/null
holders=()
ended "$u" 10 || fail "the unbind did not finish even after the holders closed"
for i in $(seq 50); do
	[ "$(cat "/sys/module/$GC573_MOD/refcnt")" = 0 ] && break
	sleep 0.1
done
echo "after the holders closed: module references $(cat "/sys/module/$GC573_MOD/refcnt")"
gc573_unload || fail "gc573 does not unload after the holders closed"
[ "$bad" = 0 ] || fail "unbind waited for the programs holding the card's ALSA nodes"
echo "the unbind did not wait for the ALSA holders, and gc573 unloaded once they closed"
