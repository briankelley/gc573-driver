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
# A holder of the card's ALSA or I2C (i2c-dev) nodes other than PipeWire
# is never overridden, not even with --yes: an unbind would wait,
# uninterruptibly, until it closes them (the I2C core always waits for
# i2c-dev users, a gc573 older than this script for ALSA files too). The
# unbind itself is bounded: if it has not finished after 10 s (a program
# opened a node after the check), the scripts say so and stop.
#
# What /proc gives about other processes is theirs to choose (a comm, a
# file name): holders are found by exact match of each fd's link target
# with the card's node paths, never by parsing, PipeWire by its executable,
# and every name is printed with non-printable characters removed.
#
# Uses NAME and say() from the script that sources it.

# The card's device nodes while a driver has it, from sysfs: its video
# and media nodes, its ALSA card's nodes and its I2C buses' i2c-dev nodes.
# $1: the PCI device's sysfs dir
gc573_card_nodes() {
	local d c n f
	for d in "$1"/video4linux/* "$1"/media[0-9]* "$1"/i2c-*/i2c-dev/i2c-*; do
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

# A process's name for messages: its comm, printable characters only
gc573_comm() {
	local c
	c=$(LC_ALL=C tr -cd '[:print:]' < "/proc/$1/comm" 2>/dev/null | head -c 32)
	printf '%s' "${c:-?}"
}

# PipeWire's own processes (pipewire, pipewire-pulse, wireplumber), by
# the executable they run: a comm is the process's to set. $1: pid
gc573_is_pw() {
	case $(readlink "/proc/$1/exe" 2>/dev/null) in
	/usr/bin/pipewire|/usr/bin/pipewire-pulse|/usr/bin/wireplumber) return 0 ;;
	/bin/pipewire|/bin/pipewire-pulse|/bin/wireplumber) return 0 ;;
	esac
	return 1
}

# "pid node comm" for each of the card's nodes a process holds open, sorted
# by pid: every /proc/PID/fd link whose target is exactly a node's path
# (find -lname; node paths from sysfs have no glob characters). $1: the
# PCI device's sysfs dir
gc573_holders() {
	local n p f match=()
	while read -r n; do
		case $n in
		/dev/*[!A-Za-z0-9/_-]* | "") continue ;;
		/dev/*) match+=(-o -lname "$n") ;;
		esac
	done < <(gc573_card_nodes "$1")
	[ ${#match[@]} -gt 0 ] || return 0
	find /proc/[0-9]*/fd -maxdepth 1 -type l \( "${match[@]:1}" \) \
		-printf '%h %l\n' 2>/dev/null |
		while read -r p f; do
			p=${p#/proc/}
			p=${p%/fd}
			case $p in *[!0-9]* | "") continue ;; esac
			printf '%s %s %s\n' "$p" "$f" "$(gc573_comm "$p")"
		done | sort -u -k1,1n -k2,2
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
		if gc573_is_pw "$p"; then
			case $f in
			/dev/snd/pcmC*) printf '%s %s\n' "$p" "PipeWire, streaming the card's audio" ;;
			esac
		else
			printf '%s %s\n' "$p" "$c"
		fi
	done <<< "$1" | sort -u -k1,1n
	return 0
}

# The holders an unbind would wait for, "pid name": every process but
# PipeWire's own that holds an ALSA or i2c-dev node of the card (PipeWire
# closes its ALSA nodes when the card goes). $1: gc573_holders output
gc573_blockers() {
	local p f c
	while read -r p f c; do
		[ -n "$p" ] || continue
		case $f in
		/dev/i2c-*) printf '%s %s\n' "$p" "$c" ;;
		/dev/snd/*) gc573_is_pw "$p" || printf '%s %s\n' "$p" "$c" ;;
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

# Unbind one device, bounded: 0 when it finished within 10 s. Otherwise
# it goes on in the background until the holders close their nodes.
# $1: the device
gc573_unbind() {
	local u i
	( echo "$1" > "/sys/bus/pci/drivers/$NAME/unbind" ) 2>/dev/null &
	u=$!
	for i in $(seq 100); do
		if ! kill -0 "$u" 2>/dev/null; then
			wait "$u"
			return
		fi
		sleep 0.1
	done
	return 3
}

# Take every card gc573 has away from it, and unload it. Refuses (status 1,
# nothing changed) when anything but PipeWire holds a node of a card and
# $1 is not 1 (--yes), and always when such a holder has an ALSA or i2c-dev
# node open (an unbind would wait for it). Status 2: the cards were
# unbound but gc573 could not be unloaded within 5 s (a holder did not let
# go); then the cards are bound to gc573 again, so that they stay usable.
# Status 3: an unbind did not finish within 10 s; it goes on, nothing
# else is done.
gc573_release() {
	local yes=$1 d h o b all="" others="" blockers="" bdfs="" hint=""
	for d in /sys/bus/pci/drivers/"$NAME"/0000:*; do
		[ -e "$d" ] || continue
		d=$(readlink -f "$d")
		bdfs="$bdfs $(basename "$d")"
		h=$(gc573_holders "$d")
		all="$all$h"$'\n'
		o=$(gc573_others "$h")
		[ -z "$o" ] || others="$others$o"$'\n'
		b=$(gc573_blockers "$h")
		[ -z "$b" ] || blockers="$blockers$b"$'\n'
	done
	if [ -n "${blockers//$'\n'/}" ]; then
		say "the card's audio or I2C nodes are open in $(gc573_names "$blockers"): an unbind would wait until they close them, so the card is left alone (--yes too). Close them and run this again"
		return 1
	fi
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
		gc573_unbind "$d" && continue
		if [ $? = 3 ]; then
			say "the unbind of $d has not finished after 10 s: a program holds the card (now: $(gc573_names "$(gc573_procs "$(gc573_holders "/sys/bus/pci/devices/$d")")")); it finishes once they close it. Nothing else was changed"
			return 3
		fi
		say "warning: could not unbind $d from $NAME"
	done
	gc573_unload_wait && return 0
	say "warning: $NAME is still in use 5 s after the card was taken from it, so it cannot be unloaded; the card goes back to it"
	for d in $bdfs; do
		echo "$d" > "/sys/bus/pci/drivers/$NAME/bind" 2>/dev/null || true
	done
	return 2
}
