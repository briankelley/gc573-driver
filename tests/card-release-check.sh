#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# tools/card-release.sh's checks, offline, on this test's own processes and
# a made-up sysfs tree: what tools/install.sh and tools/uninstall.sh rely
# on before they touch the card (delta review D2, D5, D8, D16). Root, in a
# VM (install-test.sh runs it in every matrix VM). It runs in a PID and
# mount namespace of its own: the scan of open files sees only this test's
# processes, and nothing is written outside a tmpfs. That is checked, not
# trusted (final review F6): the run inside must find another mount
# namespace than its caller's, recorded before the unshare, and be PID 1
# of its PID namespace, or it does nothing; no variable skips the unshare.
# The one thing left in the caller's file system, mktemp's directory under
# which the tmpfs is mounted, goes at the exit (a trap). No device node is
# opened but /dev/full, by this test's own processes.
#   d2-export   install.sh and uninstall.sh export LC_ALL=C before they
#               source card-release.sh
#   d2-catalog  a holder of a character device is found under another
#               language. stat's file type names are translated (Ubuntu's
#               language packs carry coreutils' catalog): a catalog of our
#               own, "character special file" in German, in a tmpfs over
#               /usr/share/locale, and LANGUAGE=xx. SKIP when no installed
#               locale lets a catalog take effect.
#   d8-opath    an O_PATH descriptor of the device is no holder, an open
#               one is; the scan starts once the O_PATH helper has said
#               which descriptor it opened, and that it is the device
#   vfio-user   gc573_vfio_user names the process holding a made-up
#               device's VFIO node (the device above)
#   d16-timeout a stat that hangs (a stand-in first in PATH, as for a file
#               on a network mount whose server has gone): the scan gives
#               up after GC573_SCAN_TIMEOUT s with status 2, and
#               gc573_vfio_user too, saying why
#   f5-status   a scan counts only when timeout and xargs exit 0, or 123
#               (some stats failed: their processes went), and it saw an
#               open file (final review F5): with a stand-in timeout that
#               exits 1, 125 (timeout's own for a bad duration, or no
#               fork), 126 or 127, or a stand-in find that lists nothing,
#               status 2 and no holders; so for a GC573_SCAN_TIMEOUT that
#               is not a whole number of seconds from 1 to 600, and the
#               message names it. A stat that exits 1 (xargs 123) and the
#               bounds 1 and 600 find the holder
#   d5-dead     gc573_dead_check on a made-up sysfs: a card in gc573's
#               dead_cards, or with driver_override gc573-dead-card, is
#               dead; neither, or no gc573 and no card, is not
#   holders-script  tests/card-holders.sh (the end of every live.sh run)
#               on a made-up card whose video node is the device: names
#               the holder and exits 1, with every card or the card's BDF;
#               0 once the node is another device; 2 with the scan's
#               message for a bad GC573_SCAN_TIMEOUT; 3 with no card
# Usage: sudo tests/card-release-check.sh   (RESULT lines; exit 1 on a FAIL)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ "$(id -u)" = 0 ] || { echo "card-release-check.sh: needs root (namespaces)" >&2; exit 2; }
# $1 --in-ns and $2 the caller's mount namespace (device:inode) inside
if [ "${1:-}" != --in-ns ]; then
	ns=$(stat -L -c %d:%i /proc/self/ns/mnt) || exit 2
	exec unshare --mount --pid --fork --mount-proc bash "$0" --in-ns "$ns"
fi
here=$(stat -L -c %d:%i /proc/self/ns/mnt 2>/dev/null) || here=
if [ -z "${2:-}" ] || [ -z "$here" ] || [ "$here" = "$2" ] || [ "$$" != 1 ]; then
	echo "card-release-check.sh: not in namespaces of its own (mount namespace ${here:-unknown}, the caller's ${2:-unknown}; pid $$, not 1): nothing done" >&2
	exit 2
fi

NAME=gc573
say() { printf '%s\n' "$*"; }
# shellcheck source=tools/card-release.sh
. "$ROOT/tools/card-release.sh"
fail=0
res() {
	printf 'RESULT\tcrc-%s\t%s\t%s\n' "$1" "$2" "$3"
	[ "$2" != FAIL ] || fail=1
}
open_pid= opath_pid= locale_bound=0
tmp=$(mktemp -d) || exit 2
# at any exit: the helpers, the mounts (this namespace's), and mktemp's
# directory, which is in the caller's /tmp. As PID 1, bash gets INT and
# TERM only with a handler of its own
cleanup() {
	[ -z "$open_pid$opath_pid" ] || kill $open_pid $opath_pid 2>/dev/null
	[ "$locale_bound" = 0 ] || umount -l /usr/share/locale
	! mountpoint -q "$tmp" || umount -l "$tmp"
	rmdir "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
mount -t tmpfs gc573-crc "$tmp" || { echo "card-release-check.sh: no tmpfs" >&2; exit 2; }
dev=/dev/full
rdev=$(LC_ALL=C stat -L -c '%t:%T' "$dev")
sleep 300 < "$dev" &
open_pid=$!
# The O_PATH holder says when its descriptor is open (final review F6): a
# scan before that would find it no holder without testing anything. The
# FIFO is open here for reading and writing, so neither side's open waits
mkfifo "$tmp/opath-ready"
exec 8<> "$tmp/opath-ready"
python3 -I -c 'import os, sys, time; fd = os.open(sys.argv[1], os.O_PATH); f = open(sys.argv[2], "w"); f.write("%d\n" % fd); f.close(); time.sleep(300)' \
	"$dev" "$tmp/opath-ready" &
opath_pid=$!
opath_fd=
read -r -t 20 opath_fd <&8 || opath_fd=
exec 8<&-
case $opath_fd in
'' | *[!0-9]*)
	echo "card-release-check.sh: the O_PATH holder (pid $opath_pid) did not open its descriptor within 20 s" >&2
	exit 2 ;;
esac
# and the open holder once it runs sleep, with the device as its stdin
for _ in $(seq 100); do
	[ "$(cat "/proc/$open_pid/comm" 2>/dev/null)" = sleep ] &&
		[ "$(LC_ALL=C stat -L -c '%t:%T' "/proc/$open_pid/fd/0" 2>/dev/null)" = "$rdev" ] && break
	sleep 0.1
done
echo "device $dev ($rdev): open in pid $open_pid (sleep), O_PATH in pid $opath_pid (python3, fd $opath_fd)"
has_pid() { grep -q "^$1 " <<< "$2"; }

# ---- d2-export
for s in install.sh uninstall.sh; do
	e=$(grep -n -m1 '^export LC_ALL=C$' "$ROOT/tools/$s" | cut -d: -f1)
	c=$(grep -n -m1 '^\. .*card-release\.sh"$' "$ROOT/tools/$s" | cut -d: -f1)
	if [ -n "$e" ] && [ -n "$c" ] && [ "$e" -lt "$c" ]; then
		res d2-export PASS "$s: export LC_ALL=C at line $e, card-release.sh sourced at line $c"
	else
		res d2-export FAIL "$s: export LC_ALL=C at line '${e:-none}', card-release.sh sourced at line '${c:-none}'"
	fi
done

# ---- d2-catalog
de="zeichenorientierte Spezialdatei"
mkdir -p "$tmp/locale/xx/LC_MESSAGES"
python3 -I - "$tmp/locale/xx/LC_MESSAGES/coreutils.mo" "$de" <<'PY'
# A GNU .mo catalog: the header and one translation, keys sorted
import struct, sys
msgs = {b"": b"Content-Type: text/plain; charset=UTF-8\n",
        b"character special file": sys.argv[2].encode()}
keys = sorted(msgs)
ids = strs = b""
ent = []
for k in keys:
    ent.append((len(k), len(ids), len(msgs[k]), len(strs)))
    ids += k + b"\0"
    strs += msgs[k] + b"\0"
n = len(keys)
kstart = 28 + 16 * n
vstart = kstart + len(ids)
kt = [x for kl, ko, vl, vo in ent for x in (kl, kstart + ko)]
vt = [x for kl, ko, vl, vo in ent for x in (vl, vstart + vo)]
with open(sys.argv[1], "wb") as f:
    f.write(struct.pack("<7I", 0x950412de, 0, n, 28, 28 + 8 * n, 0, 0))
    f.write(struct.pack("<%dI" % len(kt), *kt))
    f.write(struct.pack("<%dI" % len(vt), *vt))
    f.write(ids + strs)
PY
mount --bind "$tmp/locale" /usr/share/locale && locale_bound=1
loc=
for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
	if [ "$(env -u LC_ALL -u LC_MESSAGES LANG="$l" LANGUAGE=xx stat -L -c %F "$dev" 2>/dev/null)" = "$de" ]; then
		loc=$l
		break
	fi
done
if [ -z "$loc" ]; then
	res d2-catalog SKIP "no installed locale makes stat use the catalog (tried C.UTF-8, en_US.UTF-8)"
else
	h=$(unset LC_ALL LC_MESSAGES; export LANG="$loc" LANGUAGE=xx; gc573_fd_holders "$rdev")
	if has_pid "$open_pid" "$h"; then
		res d2-catalog PASS "LANG=$loc LANGUAGE=xx, stat -c %F says '$de': the holder is found (pid $open_pid)"
	else
		res d2-catalog FAIL "LANG=$loc LANGUAGE=xx, stat -c %F says '$de': holders '$(tr '\n' ' ' <<< "$h")', not pid $open_pid"
	fi
fi
umount /usr/share/locale && locale_bound=0

# ---- d8-opath: the O_PATH descriptor is there, and it is the device
h=$(gc573_fd_holders "$rdev")
o=$(LC_ALL=C stat -L -c '%t:%T' "/proc/$opath_pid/fd/$opath_fd" 2>/dev/null) || o=
if [ "$o" != "$rdev" ]; then
	res d8-opath FAIL "pid $opath_pid's fd $opath_fd is '${o:-gone}', not the device ($rdev): nothing tested"
elif has_pid "$open_pid" "$h" && ! has_pid "$opath_pid" "$h"; then
	res d8-opath PASS "holders: pid $open_pid (open); not pid $opath_pid (O_PATH, fd $opath_fd)"
else
	res d8-opath FAIL "holders '$(tr '\n' ' ' <<< "$h")': want pid $open_pid and not pid $opath_pid (O_PATH, fd $opath_fd)"
fi

# ---- vfio-user: a made-up device whose VFIO node is the device above
vd=$tmp/0000:99:00.0
mkdir -p "$vd/vfio-dev/vfio0"
printf '%d:%d\n' "$((16#${rdev%%:*}))" "$((16#${rdev##*:}))" > "$vd/vfio-dev/vfio0/dev"
u=$(gc573_vfio_user "$vd")
if [ "$u" = "process $open_pid (sleep)" ]; then
	res vfio-user PASS "'$u'"
else
	res vfio-user FAIL "'$u', not 'process $open_pid (sleep)'"
fi

# ---- d16-timeout: stat hangs
mkdir -p "$tmp/bin"
printf '#!/bin/sh\nexec sleep 300\n' > "$tmp/bin/stat"
chmod +x "$tmp/bin/stat"
for f in holders vfio; do
	(
		export PATH="$tmp/bin:$PATH" GC573_SCAN_TIMEOUT=2
		if [ $f = holders ]; then
			gc573_fd_holders "$rdev" > "$tmp/$f.out"
		else
			gc573_vfio_user "$vd" > "$tmp/$f.out"
		fi
		echo $? > "$tmp/$f.rc"
	) &
	w=$!
	t0=$(date +%s)
	for _ in $(seq 150); do
		kill -0 "$w" 2>/dev/null || break
		sleep 0.1
	done
	dt=$(($(date +%s) - t0))
	if kill -0 "$w" 2>/dev/null; then
		res d16-timeout FAIL "$f: still scanning after $dt s with GC573_SCAN_TIMEOUT=2"
		continue
	fi
	rc=$(cat "$tmp/$f.rc")
	o=$(cat "$tmp/$f.out")
	if [ "$rc" = 2 ] && { [ $f = holders ] || [[ $o == *"did not finish within 2 s"* ]]; }; then
		res d16-timeout PASS "$f: status 2 after $dt s${o:+, '$o'}"
	else
		res d16-timeout FAIL "$f: status $rc after $dt s, '$o'"
	fi
done

# ---- f5-status: what counts as a finished scan
# $1 the case, $2 a directory first in PATH (or none), $3
# GC573_SCAN_TIMEOUT, $4 the status wanted: 0 must find the open holder,
# 2 must print no holder
f5() {
	local h r l
	h=$(if [ -n "$2" ]; then PATH="$2:$PATH"; fi; GC573_SCAN_TIMEOUT=$3; gc573_fd_holders "$rdev")
	r=$?
	l=$(printf '%s' "$h" | tr '\n' ';')
	if [ "$r" != "$4" ]; then
		res f5-status FAIL "$1: status $r, holders '$l' (want status $4)"
	elif [ "$r" = 0 ] && ! has_pid "$open_pid" "$h"; then
		res f5-status FAIL "$1: status 0, holders '$l' without pid $open_pid"
	elif [ "$r" = 2 ] && [ -n "$h" ]; then
		res f5-status FAIL "$1: status 2, but holders '$l'"
	else
		res f5-status PASS "$1: status $r, holders '$l'"
	fi
}
# a stand-in $2 in a directory of its own, exiting $3 after $4 (or nothing)
standin() {
	mkdir -p "$tmp/f5/$1"
	printf '#!/bin/sh\n%s\nexit %s\n' "${4:-}" "$3" > "$tmp/f5/$1/$2"
	chmod +x "$tmp/f5/$1/$2"
}
for n in 1 125 126 127; do
	standin "timeout-$n" timeout "$n"
	f5 "timeout exits $n" "$tmp/f5/timeout-$n" 20 2
done
standin find-none find 0
f5 "find lists no open file" "$tmp/f5/find-none" 20 2
standin stat-1 stat 1 "$(command -v stat) \"\$@\""
f5 "every stat exits 1 after its output (xargs 123)" "$tmp/f5/stat-1" 20 0
for v in x 0 601 010 1.5 99999999999999999999 ''; do
	f5 "GC573_SCAN_TIMEOUT='$v'" "" "$v" 2
	m=$(GC573_SCAN_TIMEOUT=$v; gc573_scan_failed)
	if [[ $m == *"GC573_SCAN_TIMEOUT is '$v'"* ]]; then
		res f5-status PASS "GC573_SCAN_TIMEOUT='$v': '$m'"
	else
		res f5-status FAIL "GC573_SCAN_TIMEOUT='$v': the message '$m' does not name it"
	fi
done
for v in 1 600; do
	f5 "GC573_SCAN_TIMEOUT=$v" "" "$v" 0
done

# ---- d5-dead: a made-up sysfs
sys=$tmp/sys
card=$sys/bus/pci/devices/0000:07:00.0
mkdir -p "$sys/module/$NAME/parameters" "$card"
echo 0x1461 > "$card/vendor"
echo 0x0054 > "$card/device"
dead() {
	local o r
	o=$(GC573_SYSFS=$sys; gc573_dead_check 2>&1)
	r=$?
	printf '%s|%s' "$r" "$o"
}
echo 0000:07:00.0 > "$sys/module/$NAME/parameters/dead_cards"
echo '(null)' > "$card/driver_override"
d1=$(dead)
: > "$sys/module/$NAME/parameters/dead_cards"
echo gc573-dead-card > "$card/driver_override"
d2=$(dead)
echo '(null)' > "$card/driver_override"
d3=$(dead)
rm -r "$sys/module/$NAME" "$card"
d4=$(dead)
# $1 the case, $2 dead()'s "STATUS|MESSAGE" (the message may hold a "|"),
# $3 the status wanted, $4 a part of the message wanted
dead_res() {
	local r=${2%%|*} o=${2#*|}
	if [ "$r" = "$3" ] && [[ $o == *"$4"* ]]; then
		res d5-dead PASS "$1: status $r${o:+, '$o'}"
	else
		res d5-dead FAIL "$1: status $r, '$o' (want status $3${4:+ and $4})"
	fi
}
dead_res listed "$d1" 0 0000:07:00.0
dead_res driver_override "$d2" 0 gc573-dead-card
dead_res neither "$d3" 1 ""
dead_res nothing "$d4" 1 ""

# ---- holders-script: a made-up card, its video node the device above
hs=$tmp/hsys
hc=$hs/bus/pci/devices/0000:07:00.0
mkdir -p "$hc/video4linux/video0" "$hc/sound/card0/controlC0" "$tmp/nosys"
echo 0x1461 > "$hc/vendor"
echo 0x0054 > "$hc/device"
printf '%d:%d\n' "$((16#${rdev%%:*}))" "$((16#${rdev##*:}))" > "$hc/video4linux/video0/dev"
echo 250:250 > "$hc/sound/card0/controlC0/dev"
# $1 the case, $2 the status wanted, $3 the output wanted (a glob), then
# card-holders.sh's environment (VAR=VALUE), and after a -- its arguments
hs_res() {
	local what=$1 want_r=$2 want_o=$3 o r e=()
	shift 3
	while [ $# -gt 0 ] && [ "$1" != -- ]; do
		e+=("$1")
		shift
	done
	[ "${1:-}" != -- ] || shift
	o=$(env "${e[@]}" bash "$ROOT/tests/card-holders.sh" "$@" 2>&1)
	r=$?
	# shellcheck disable=SC2053
	if [ "$r" = "$want_r" ] && [[ $o == $want_o ]]; then
		res holders-script PASS "$what: status $r, '$o'"
	else
		res holders-script FAIL "$what: status $r, '$o' (want status $want_r, '$want_o')"
	fi
}
hs_res "every card" 1 "0000:07:00.0: sleep (pid $open_pid): /dev/video0" GC573_SYSFS="$hs"
hs_res "the card's BDF" 1 "0000:07:00.0: sleep (pid $open_pid): /dev/video0" GC573_SYSFS="$hs" -- 0000:07:00.0
echo 250:251 > "$hc/video4linux/video0/dev"
hs_res "no holder" 0 "" GC573_SYSFS="$hs"
hs_res "a bad GC573_SCAN_TIMEOUT" 2 "0000:07:00.0: GC573_SCAN_TIMEOUT is 'x', *" GC573_SYSFS="$hs" GC573_SCAN_TIMEOUT=x
hs_res "no card" 3 "no GC573" GC573_SYSFS="$tmp/nosys"

exit $fail
