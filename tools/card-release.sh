# SPDX-License-Identifier: GPL-2.0
# Sourced by tools/install.sh and tools/uninstall.sh (bash, as root): take
# the card away from a loaded gc573 so that gc573 can be unloaded.
#
# On a PipeWire desktop WirePlumber keeps the card's ALSA control node open
# for as long as it manages the card, so "modprobe -r gc573" fails whenever
# gc573 has the card. Once the device is unbound from gc573, its nodes go
# away and PipeWire lets go of them, about 0.2 s later; then gc573 unloads.
# Anything else holding one of the card's nodes (OBS, a capture) would lose
# the card: then the scripts name it and leave the card alone, unless
# --yes. So does PipeWire while it holds one of the card's PCM nodes: a
# stream runs through it then (OBS's PipeWire source, pw-record), and
# PipeWire closes an idle node's PCM after its suspend timeout.
#
# Uses NAME and say() from the script that sources it.

GC573_PW_COMMS=" wireplumber pipewire pipewire-pulse "

# The card's device nodes while a driver has it, from sysfs: its video
# and media nodes, and its ALSA card's nodes. $1: the PCI device's sysfs dir
gc573_card_nodes() {
	local d c n f
	for d in "$1"/video4linux/* "$1"/media[0-9]*; do
		[ -e "$d" ] && printf '/dev/%s\n' "$(basename "$d")"
	done
	for c in "$1"/sound/card[0-9]*; do
		[ -e "$c" ] || continue
		n=${c##*card}
		for f in /dev/snd/controlC"$n" /dev/snd/pcmC"$n"D* /dev/snd/hwC"$n"D* /dev/snd/midiC"$n"D*; do
			[ -e "$f" ] && printf '%s\n' "$f"
		done
	done
	return 0
}

# "pid node comm" for each of the card's nodes a process holds open
# (/proc/*/fd), sorted by pid. $1: the PCI device's sysfs dir
gc573_holders() {
	local nodes p f
	nodes=$(gc573_card_nodes "$1" | tr '\n' ' ')
	[ -n "$nodes" ] || return 0
	find /proc/[0-9]*/fd -maxdepth 1 -type l -printf '%h %l\n' 2>/dev/null |
		awk -v n=" $nodes" 'index(n, " " $2 " ") { split($1, p, "/"); print p[3], $2 }' |
		sort -u -k1,1n -k2,2 |
		while read -r p f; do
			printf '%s %s %s\n' "$p" "$f" "$(cat "/proc/$p/comm" 2>/dev/null || echo '?')"
		done
	return 0
}

# "pid comm", one line per process; $1: gc573_holders output
gc573_procs() {
	local p f c
	while read -r p f c; do
		[ -n "$p" ] && printf '%s %s\n' "$p" "$c"
	done <<< "$1" | sort -u -k1,1n
	return 0
}

# The holders that would lose the card, "pid name", one per process: every
# process but PipeWire's own, and PipeWire's too while it holds a PCM node
# (a stream). $1: gc573_holders output
gc573_others() {
	local p f c
	while read -r p f c; do
		[ -n "$p" ] || continue
		case $GC573_PW_COMMS in
		*" $c "*)
			case $f in
			/dev/snd/pcmC*) printf '%s %s\n' "$p" "PipeWire, streaming the card's audio" ;;
			esac ;;
		*) printf '%s %s\n' "$p" "$c" ;;
		esac
	done <<< "$1" | sort -u -k1,1n
	return 0
}

# "name (pid P), ..." for messages; $1: "pid name" lines
gc573_names() {
	awk 'NF { p = $1; sub(/^[^ ]+ /, ""); printf "%s%s (pid %s)", (n++ ? ", " : ""), $0, p }' <<< "$1"
}

# gc573 unloaded once nothing holds it any more: up to 5 s for its users
# (PipeWire, after an unbind) to let go. rmmod when modprobe cannot: once
# an uninstall that could not unload gc573 has removed its files,
# "modprobe -r" fails with "Module gc573 not found" (kmod 31), even
# though nothing holds it
gc573_unload_wait() {
	local i
	grep -q "^$NAME " /proc/modules || return 0
	for i in $(seq 50); do
		[ "$(cat "/sys/module/$NAME/refcnt" 2>/dev/null || echo 0)" = 0 ] && break
		sleep 0.1
	done
	modprobe -r "$NAME" 2>/dev/null || rmmod "$NAME" 2>/dev/null
}

# Take every card gc573 has away from it, and unload it. Refuses (status 1,
# nothing changed) when anything but PipeWire holds a node of a card and
# $1 is not 1 (--yes). Status 2: the cards were unbound but gc573 could not
# be unloaded within 5 s (a holder did not let go); then the cards are
# bound to gc573 again, so that they stay usable.
gc573_release() {
	local yes=$1 d h o all="" others="" bdfs="" hint=""
	for d in /sys/bus/pci/drivers/"$NAME"/0000:*; do
		[ -e "$d" ] || continue
		d=$(readlink -f "$d")
		bdfs="$bdfs $(basename "$d")"
		h=$(gc573_holders "$d")
		all="$all$h"$'\n'
		o=$(gc573_others "$h")
		[ -z "$o" ] || others="$others$o"$'\n'
	done
	if [ -n "${others//$'\n'/}" ]; then
		if [ "$yes" != 1 ]; then
			case $others in
			*"PipeWire, streaming"*) hint=" (for PipeWire: stop what records the card's audio through it)" ;;
			esac
			say "the card is in use by $(gc573_names "$others"): close it$hint and run this again, or run this with --yes, and it loses the card"
			return 1
		fi
		say "the card is in use by $(gc573_names "$others"): --yes, so it loses the card now"
	fi
	if [ -n "${all//$'\n'/}" ]; then
		say "taking the card from $NAME (open now by $(gc573_names "$(gc573_procs "$all")"))"
	fi
	for d in $bdfs; do
		echo "$d" > "/sys/bus/pci/drivers/$NAME/unbind" 2>/dev/null ||
			say "warning: could not unbind $d from $NAME"
	done
	gc573_unload_wait && return 0
	say "warning: $NAME is still in use 5 s after the card was taken from it, so it cannot be unloaded; the card goes back to it"
	for d in $bdfs; do
		echo "$d" > "/sys/bus/pci/drivers/$NAME/bind" 2>/dev/null || true
	done
	return 2
}
