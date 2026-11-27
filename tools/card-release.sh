# SPDX-License-Identifier: GPL-2.0
# Sourced by tools/install.sh and tools/uninstall.sh (bash, as root): take
# the card away from a loaded gc573 so that gc573 can be unloaded, and the
# checks before anything touches the card.
#
# On a desktop the sound server keeps the card's ALSA control node open for
# as long as it manages the card (WirePlumber for PipeWire, also
# pipewire-media-session, and PulseAudio), so "modprobe -r gc573" fails
# whenever gc573 has the card. Once the device is unbound from gc573, its
# nodes go away and the sound server lets go of them, about 0.2 s later;
# then gc573 unloads. Anything else holding one of the card's nodes (OBS, a
# capture) would lose the card: then the scripts name it and leave the
# card alone, unless --yes. So does a sound server while it holds one of
# the card's PCM nodes: a stream runs through it then (OBS's PipeWire
# source, pw-record), and it closes an idle node's PCM by itself.
# A holder of the card's ALSA or I2C (i2c-dev) nodes other than a sound
# server is never overridden, not even with --yes: an unbind would wait,
# uninterruptibly, until it closes them (the I2C core always waits for
# i2c-dev users; a gc573 older than this script waits for ALSA files too).
# gc573 has i2c-dev nodes only with its i2c_bus1 or i2c_bus02 parameter.
#
# The unbind itself is bounded: if it has not finished after 10 s (a
# program opened a node after the check, or holds one that no /proc fd
# shows: in flight in a unix socket), the scripts say so and stop. Its
# writer is recorded in GC573_UNBIND_PID. While that writer runs, or while
# the card has no driver but still has a driver's devices or interrupt
# vectors (an unbind still waits), the scripts refuse before they touch
# the card: whatever takes the device's lock (driverctl, a bind, on some
# kernels a read of driver_override) would wait for that unbind too.
#
# What /proc gives about other processes is theirs to choose (a comm, a
# file name, the path a node was opened by): a holder is found by the
# device number of each open file (stat -L of /proc/PID/fd/N, the file
# itself) against the card's nodes' sysfs dev files, never by a name or a
# path; a sound server by the executable it runs; and every name is printed
# with non-printable characters removed. The file type is stat's raw mode
# (%f), not its name (%F), which a language catalog translates: under
# another language no file would be a holder. An O_PATH descriptor is no
# holder: it holds nothing open (it needs no permission on the node, so
# any user could otherwise block the scripts, and an unbind does not wait
# for it). The scan stats every open file, and a file on a network mount
# whose server has gone can stall that: it gets GC573_SCAN_TIMEOUT seconds,
# and a scan that does not finish makes the scripts refuse.
#
# Uses NAME and say() from the script that sources it.

GC573_PCI_ID=${GC573_PCI_ID:-1461:0054}
GC573_UNBIND_PID=${GC573_UNBIND_PID:-/run/gc573-unbind.pid}
GC573_VFIO_CLASS=${GC573_VFIO_CLASS:-/sys/class/vfio}
GC573_SCAN_TIMEOUT=${GC573_SCAN_TIMEOUT:-20}

# The card's PCI devices (GC573_PCI_ID), one sysfs dir per line
gc573_cards() {
	local d
	for d in /sys/bus/pci/devices/*; do
		[ "$(cat "$d/vendor" 2>/dev/null)" = "0x${GC573_PCI_ID%%:*}" ] &&
			[ "$(cat "$d/device" 2>/dev/null)" = "0x${GC573_PCI_ID##*:}" ] &&
			printf '%s\n' "$d"
	done
	return 0
}

# A sysfs dev file's "MAJOR:MINOR" (decimal), as stat's %t:%T prints a
# device number (hex); status 1 for anything else. $1: the dev file's text
gc573_hexdev() {
	case $1 in
	*[!0-9:]* | :* | *: | *:*:*) return 1 ;;
	*:*) printf '%x:%x\n' "$((10#${1%%:*}))" "$((10#${1##*:}))" ;;
	*) return 1 ;;
	esac
}

# The card's device nodes while a driver has it, "RDEV NODE" per node
# (RDEV as gc573_hexdev prints it): its video and media nodes, its ALSA
# card's nodes and its I2C buses' i2c-dev nodes, from sysfs. $1: the PCI
# device's sysfs dir
gc573_card_nodes() {
	local d r n
	for d in "$1"/video4linux/*/dev "$1"/media[0-9]*/dev \
		 "$1"/i2c-*/i2c-dev/i2c-*/dev "$1"/sound/card[0-9]*/*/dev; do
		[ -r "$d" ] || continue
		r=$(gc573_hexdev "$(cat "$d" 2>/dev/null)") || continue
		n=${d%/dev}
		n=${n##*/}
		case $d in
		*/sound/*) n=snd/$n ;;
		esac
		printf '%s /dev/%s\n' "$r" "$n"
	done
	return 0
}

# An O_PATH file descriptor (O_PATH, 010000000, in the flags of
# /proc/PID/fdinfo/N): it names a file but holds nothing open. Status 1
# when it is not one, or when that cannot be read (then it counts as a
# holder). $1: pid, $2: fd
gc573_fd_opath() {
	local fl
	fl=$(awk '$1 == "flags:" { print $2; exit }' "/proc/$1/fdinfo/$2" 2>/dev/null) || return 1
	case $fl in
	'' | *[!0-7]*) return 1 ;;
	esac
	(((8#$fl & 8#10000000) != 0))
}

# The message for a scan of open files that did not finish
gc573_scan_failed() {
	printf 'the scan of open files did not finish within %s s (a file on a network mount that does not answer?)' \
		"$GC573_SCAN_TIMEOUT"
}

# "PID RDEV" for every open character device file, in any process, whose
# device number is one of the RDEVs given (gc573_hexdev's form), sorted;
# O_PATH descriptors are left out. stat -L of /proc/PID/fd/N describes the
# open file itself, whatever path it was opened by; its raw mode (%f, hex)
# is a character device's when the file type bits read 2 (S_IFCHR,
# 0020000). Status 2, and nothing printed, when the stats did not finish
# within GC573_SCAN_TIMEOUT s (timeout kills them, its process group);
# otherwise 0: processes come and go meanwhile, and a file that went is no
# holder.
gc573_fd_holders() {
	local want=" $* " out p f r
	out=$(find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 -type l -print0 2>/dev/null |
		{
			LC_ALL=C timeout -k 2 "$GC573_SCAN_TIMEOUT" xargs -0 -r stat -L -c '%f|%t:%T|%n' 2>/dev/null
			echo "gc573-scan-status $?"
		}) || :
	case ${out##*gc573-scan-status } in
	124 | 137) return 2 ;;
	esac
	awk -F'|' -v want="$want" '
		$1 ~ /^2[0-9a-f][0-9a-f][0-9a-f]$/ && index(want, " " $2 " ") {
			n = $3
			sub(/^\/proc\//, "", n)
			p = n
			sub(/\/.*/, "", p)
			f = n
			sub(/^[0-9]+\/fd\//, "", f)
			if (p ~ /^[0-9]+$/ && f ~ /^[0-9]+$/)
				print p, f, $2
		}' <<< "${out%gc573-scan-status *}" |
		while read -r p f r; do
			gc573_fd_opath "$p" "$f" || printf '%s %s\n' "$p" "$r"
		done | sort -u -k1,1n -k2,2
	return 0
}

# A process's name for messages: its comm, printable characters only
gc573_comm() {
	local c
	c=$(LC_ALL=C tr -cd '[:print:]' 2>/dev/null < "/proc/$1/comm" | head -c 32) || true
	printf '%s' "${c:-?}"
}

# A sound server's own process, by the executable it runs, which only root
# can put there (a comm is the process's to set): PipeWire (pipewire,
# pipewire-pulse, wireplumber, pipewire-media-session) or PulseAudio. The
# file that runs must be that executable (device and inode), not another
# one mounted over its path in a mount namespace of the process's own.
# Prints which. $1: pid
gc573_sound_server() {
	local e i
	e=$(readlink "/proc/$1/exe" 2>/dev/null) || return 1
	case $e in
	/usr/bin/* | /bin/*) ;;
	*) return 1 ;;
	esac
	i=$(stat -L -c %d:%i "/proc/$1/exe" 2>/dev/null) || return 1
	[ -n "$i" ] && [ "$i" = "$(stat -L -c %d:%i "$e" 2>/dev/null)" ] || return 1
	case ${e##*/} in
	pipewire | pipewire-pulse | wireplumber | pipewire-media-session) echo PipeWire ;;
	pulseaudio) echo PulseAudio ;;
	*) return 1 ;;
	esac
}

# "pid node comm" for each node in $1 (gc573_card_nodes output) a process
# holds open, sorted by pid. Status 2 when the scan did not finish
gc573_holders_of() {
	local p r h
	[ -n "$1" ] || return 0
	# shellcheck disable=SC2046
	h=$(gc573_fd_holders $(awk '{ print $1 }' <<< "$1")) || return 2
	while read -r p r; do
		[ -n "$p" ] || continue
		printf '%s %s %s\n' "$p" "$(awk -v r="$r" '$1 == r { print $2; exit }' <<< "$1")" \
			"$(gc573_comm "$p")"
	done <<< "$h" | sort -u -k1,1n -k2,2
	return 0
}

# "pid node comm" for each of the card's nodes a process holds open,
# sorted by pid; status 2 when the scan did not finish. $1: the PCI
# device's sysfs dir
gc573_holders() {
	gc573_holders_of "$(gc573_card_nodes "$1")"
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
# process but a sound server's own, and a sound server's too while it
# holds a PCM node (a stream). $1: gc573_holders output
gc573_others() {
	local p f c s
	while read -r p f c; do
		[ -n "$p" ] || continue
		if s=$(gc573_sound_server "$p"); then
			case $f in
			/dev/snd/pcmC*) printf '%s %s\n' "$p" "$s, streaming the card's audio" ;;
			esac
		else
			printf '%s %s\n' "$p" "$c"
		fi
	done <<< "$1" | sort -u -k1,1n
	return 0
}

# The holders an unbind would wait for, "pid name": every process but a
# sound server's own that holds an ALSA or i2c-dev node of the card (a
# sound server closes its ALSA nodes when the card goes). $1:
# gc573_holders output
gc573_blockers() {
	local p f c
	while read -r p f c; do
		[ -n "$p" ] || continue
		case $f in
		/dev/i2c-*) printf '%s %s\n' "$p" "$c" ;;
		/dev/snd/*) gc573_sound_server "$p" > /dev/null || printf '%s %s\n' "$p" "$c" ;;
		esac
	done <<< "$1" | sort -u -k1,1n
	return 0
}

# "name (pid P), ..." for messages; $1: "pid name" lines
gc573_names() {
	awk 'NF { p = $1; sub(/^[^ ]+ /, ""); printf "%s%s (pid %s)", (n++ ? ", " : ""), $0, p }' <<< "$1"
}

# A process that uses the card through VFIO, found by device number: it
# holds the card's VFIO group node (/dev/vfio/N) or its VFIO device node
# (iommufd: /dev/vfio/devices/vfioN) open. Prints "process PID (comm)",
# with the virtual machine's name if its command line has one, for the
# first such process; nothing if none. Status 2, with gc573_scan_failed's
# message printed, when the scan did not finish; otherwise 0: processes
# come and go meanwhile. $1: the PCI device's sysfs dir
gc573_vfio_user() {
	local d r want="" p vm
	if [ -e "$1/iommu_group" ]; then
		d=$GC573_VFIO_CLASS/$(basename "$(readlink -f "$1/iommu_group")")/dev
		r=$(gc573_hexdev "$(cat "$d" 2>/dev/null)") && want="$want $r"
	fi
	for d in "$1"/vfio-dev/vfio*/dev; do
		r=$(gc573_hexdev "$(cat "$d" 2>/dev/null)") && want="$want $r"
	done
	[ -n "$want" ] || return 0
	# shellcheck disable=SC2086
	if ! p=$(gc573_fd_holders $want); then
		gc573_scan_failed
		return 2
	fi
	p=$(awk 'NR == 1 { print $1 }' <<< "$p")
	[ -n "$p" ] || return 0
	vm=$(tr '\0' ' ' 2>/dev/null < "/proc/$p/cmdline" | LC_ALL=C tr -cd '[:print:]' |
		grep -o 'guest=[^, ]*' | head -1) || true
	printf 'process %s (%s)%s\n' "$p" "$(gc573_comm "$p")" "${vm:+, virtual machine ${vm#guest=}}"
	return 0
}

# A process's start time (/proc/PID/stat field 22), which tells it from a
# later process with the same pid; nothing if there is no such process
gc573_starttime() {
	local s
	s=$(cat "/proc/$1/stat" 2>/dev/null) || return 0
	s=${s##*) }
	# shellcheck disable=SC2086
	set -- $s
	printf '%s\n' "${20:-}"
}

# An unbind of a card that has not finished: the writer gc573_unbind()
# recorded still runs, or a card has no driver but still has a driver's
# devices, MSI vectors or interrupt handler (an unbind that waits in the
# I2C core for an i2c-dev holder has only the vectors and the handler
# left). Prints why; status 0 when one is pending.
gc573_unbind_pending() {
	local pid start b d f irq
	if read -r pid start b 2>/dev/null < "$GC573_UNBIND_PID"; then
		if [ -n "$start" ] && [ "$(gc573_starttime "$pid")" = "$start" ]; then
			printf 'the unbind of %s that an earlier run started (pid %s) has not finished\n' \
				"$b" "$pid"
			return 0
		fi
		rm -f "$GC573_UNBIND_PID"
	fi
	while read -r d; do
		{ [ -n "$d" ] && [ ! -e "$d/driver" ]; } || continue
		for f in "$d"/i2c-* "$d"/sound/card[0-9]* "$d"/video4linux/* "$d"/msi_irqs/*; do
			if [ -e "$f" ]; then
				printf '%s has no driver but still has %s: an unbind has not finished\n' \
					"$(basename "$d")" "${f#"$d"/}"
				return 0
			fi
		done
		irq=$(cat "$d/irq" 2>/dev/null) || irq=
		if [ -n "$irq" ] && [ "$irq" != 0 ] &&
		   awk -v i="$irq:" -v n="$NAME" '$1 == i { for (k = 2; k <= NF; k++) if ($k == n) f = 1 } END { exit !f }' /proc/interrupts; then
			printf '%s has no driver but %s still has its interrupt: an unbind has not finished\n' \
				"$(basename "$d")" "$NAME"
			return 0
		fi
	done < <(gc573_cards)
	return 1
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
# it goes on in the background until the holders close their nodes, on
# none of the caller's files (a pipe or an ssh session reading the
# script's output would wait for it too), with its pid and start time in
# GC573_UNBIND_PID. $1: the device
gc573_unbind() {
	local u i
	( echo "$1" > "/sys/bus/pci/drivers/$NAME/unbind" ) < /dev/null > /dev/null 2>&1 &
	u=$!
	printf '%s %s %s\n' "$u" "$(gc573_starttime "$u")" "$1" > "$GC573_UNBIND_PID" 2>/dev/null || true
	for i in $(seq 100); do
		if ! kill -0 "$u" 2>/dev/null; then
			rm -f "$GC573_UNBIND_PID"
			wait "$u"
			return
		fi
		sleep 0.1
	done
	return 3
}

# Take every card gc573 has away from it, and unload it. Refuses (status 1,
# nothing changed) when anything but a sound server holds a node of a card
# and $1 is not 1 (--yes), always when such a holder has an ALSA or
# i2c-dev node open (an unbind would wait for it), and when the scan for
# holders did not finish (gc573_fd_holders). Status 2: the cards were
# unbound but gc573 could not be unloaded within 5 s (a holder did not let
# go); then the cards are bound to gc573 again, so that they stay usable.
# Status 3: an unbind did not finish within 10 s (it goes on, nothing else
# is done), or one from an earlier run is still pending.
gc573_release() {
	local yes=$1 d h o b n why all="" others="" blockers="" bdfs="" hint="" nodes=""
	# before anything that takes a device's lock, which waits for that unbind
	if why=$(gc573_unbind_pending); then
		say "$why: a program holds the card; it finishes once that program closes it. Nothing was changed"
		return 3
	fi
	for d in /sys/bus/pci/drivers/"$NAME"/0000:*; do
		[ -e "$d" ] || continue
		d=$(readlink -f "$d")
		bdfs="$bdfs $(basename "$d")"
		n=$(gc573_card_nodes "$d")
		nodes="$nodes$n"$'\n'
		if ! h=$(gc573_holders_of "$n"); then
			say "could not check which programs have the card open: $(gc573_scan_failed). The card is left alone; nothing was changed"
			return 1
		fi
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
			*"PipeWire, streaming"* | *"PulseAudio, streaming"*)
				hint=" (for a sound server: stop what records the card's audio through it)" ;;
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
			# the nodes are gone from sysfs by now: their numbers from before
			if h=$(gc573_holders_of "$(sed '/^$/d' <<< "$nodes")"); then
				h=$(gc573_procs "$h")
				if [ -n "$h" ]; then
					h="now: $(gc573_names "$h")"
				else
					h="no process shows it open: one may be in flight between programs"
				fi
			else
				h=$(gc573_scan_failed)
			fi
			say "the unbind of $d has not finished after 10 s: a program holds the card ($h); it finishes once that program closes it. Run this again after that. Nothing else was changed"
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
