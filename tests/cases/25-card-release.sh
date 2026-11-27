#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# tools/card-release.sh, which install.sh and uninstall.sh use to take the
# card from a loaded gc573 (security review of a0adb1d, F6 and F7; fix
# review N3, N4, N5), with the bus-1 adapter on (i2c_bus1=1):
# - an i2c-dev holder of bus 1 and an ALSA holder of the control node
#   (sleep, as any user can) are refused even with --yes (status 1), and
#   the card stays bound: an unbind would wait for them;
# - so is an ALSA holder that opened the node through a private bind mount
#   (its fd's path is not /dev/snd/...): holders go by device number;
# - a regular file that a private tmpfs over /dev names /dev/snd/controlC*
#   is no holder;
# - a holder that names itself "wireplumber" is not PipeWire, nor is one
#   that runs another executable mounted over /usr/bin/pipewire in a mount
#   namespace of its own: both are refused as ALSA holders; the desktop's
#   own WirePlumber is PipeWire;
# - a video holder whose comm is full of terminal escapes is named with
#   printable characters only;
# - a process holding a file named "x<newline>1 /dev/videoN" is no holder;
# - the VFIO check (gc573_vfio_user) under /proc churn, with a command
#   line long enough that its name lookup's head ends early, in a shell
#   with set -euo pipefail as install.sh's: it finds the holder of the
#   card's VFIO device node every time (here the video node stands in,
#   through a fake sysfs dir);
# - an i2c-dev node in flight in a unix socket, which no /proc fd shows:
#   the unbind does not finish within 10 s (status 3), and then, from the
#   recorded writer and from what the half-unbound card still has, the
#   unbind counts as pending: a second release refuses at once (status 3)
#   instead of waiting on the device lock; once the holder ends, the
#   unbind finishes and nothing is pending.
# Each release runs bounded: before these fixes some of them unbind and
# block until the holder closes, so after 30 s the case kills the holder
# (which ends the unbind) and fails.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

cr=$GC573_TESTS/../tools/card-release.sh
[ -f "$cr" ] || skip "no tools/card-release.sh next to tests/ (tools/vmbuild.sh syncs it)"
work=$(mktemp -d)
NAME=$GC573_MOD
GC573_UNBIND_PID=$work/unbind.pid
say() { printf '%s\n' "$*"; }
# shellcheck source=tools/card-release.sh
. "$cr"

dev=/sys/bus/pci/devices/$GC573_BDF
holders=()

cleanup() {
	for p in "${holders[@]}"; do kill "$p" 2>/dev/null; done
	wait 2>/dev/null
	gc573_loaded && gc573_unload
	rm -rf "$work"
}

gc573_load i2c_bus1=1 || fail "insmod failed"
trap cleanup EXIT
vdev=$(gc573_video_dev) || fail "no video device"
i2c=""
for a in "$dev"/i2c-*; do
	[ "$(cat "$a/name")" = "gc573 $GC573_BDF bus 1" ] && i2c=/dev/$(basename "$a")
done
[ -c "$i2c" ] || fail "no i2c-dev node for bus 1"
c=$(ls -d "$dev"/sound/card[0-9]* 2>/dev/null | head -1)
ctl=/dev/snd/controlC${c##*card}
[ -c "$ctl" ] || fail "no ALSA control node"
# its device number as stat prints it (gc573_hexdev's form), without the
# script under test
ctl_rdev=$(stat -L -c '%t:%T' "$ctl") || fail "cannot stat $ctl"
bad=0

# Process $1 has file $2 open (within 2 s): every holder is checked, so
# that a holder that holds nothing cannot pass a case
holds() {
	local i f
	for i in $(seq 20); do
		for f in /proc/"$1"/fd/*; do
			[ "$(readlink "$f" 2>/dev/null)" = "$2" ] && return 0
		done
		sleep 0.1
	done
	return 1
}

# Process $1's standard input is, within 2 s, the character device with
# number $2 (gc573_hexdev's form), or a regular file for $2 = file
stdin_is() {
	local i t
	for i in $(seq 20); do
		t=$(stat -L -c '%F|%t:%T' "/proc/$1/fd/0" 2>/dev/null)
		case $2 in
		file) case $t in regular*) return 0 ;; esac ;;
		*) [ "$t" = "character special file|$2" ] && return 0 ;;
		esac
		sleep 0.1
	done
	return 1
}

# Start a holder of file $1: "${@:2}" runs in the background and opens it;
# its pid in $hp
hold() {
	"${@:2}" &
	hp=$!
	holders+=("$hp")
	holds "$hp" "$1" || fail "the holder (pid $hp) does not hold $1"
}

# Start sleep with file $1 as its standard input. The redirection goes on
# the background command itself: bash gives a background command of a
# non-interactive shell /dev/null as its input otherwise
hold_open() {
	sleep 600 < "$1" &
	hp=$!
	holders+=("$hp")
	holds "$hp" "$1" || fail "sleep (pid $hp) does not hold $1"
}

# The python holder $1 has set its comm (within 2 s)
renamed() {
	local i
	for i in $(seq 20); do
		[ "$(cat "/proc/$1/comm" 2>/dev/null)" != python3 ] && return 0
		sleep 0.1
	done
	return 1
}

# gc573_release $1 in the background, at most 30 s; then the holder $2 is
# killed (it ends an unbind that waits for it). Output in $out, status $rc,
# seconds in $secs
release() {
	local i t0
	t0=$(date +%s)
	gc573_release "$1" > "$work/rel.out" 2>&1 &
	local r=$!
	for i in $(seq 300); do
		kill -0 "$r" 2>/dev/null || break
		sleep 0.1
	done
	if kill -0 "$r" 2>/dev/null; then
		echo "BAD:  gc573_release $1 still running after 30 s: killing holder $2"
		kill "$2"
		wait "$r"
		rc=124
		bad=1
	else
		wait "$r"
		rc=$?
	fi
	secs=$(($(date +%s) - t0))
	out=$(cat "$work/rel.out")
	echo "$out" | sed 's/^/  > /'
}

# The card is still bound (and loaded) after a refusal; rebind otherwise
still_bound() {
	if gc573_bound; then
		return 0
	fi
	echo "BAD:  the card was unbound: $1"
	bad=1
	gc573_loaded || gc573_load i2c_bus1=1
	gc573_bound || echo "$GC573_BDF" > "/sys/bus/pci/drivers/$GC573_MOD/bind"
	sleep 1
	vdev=$(gc573_video_dev)
}

# $1: what; refused with status 1 and the holder $2 named
expect_refused() {
	if [ "$rc" = 1 ] && grep -q "(pid $2)" <<< "$out"; then
		echo "ok:   $1: refused, holder named"
	else
		echo "BAD:  $1: status $rc (expected 1, naming pid $2)"
		bad=1
	fi
}

stop() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }

echo "-- i2c-dev holder, --yes"
hold_open "$i2c"
release 1 "$hp"
expect_refused "i2c-dev holder" "$hp"
still_bound "i2c-dev holder"
stop "$hp"

echo "-- ALSA control holder, --yes"
hold_open "$ctl"
release 1 "$hp"
expect_refused "ALSA holder" "$hp"
still_bound "ALSA holder"
stop "$hp"

echo "-- ALSA control holder through a private bind mount of /dev/snd, --yes"
mkdir "$work/snd"
unshare -m sh -c 'mount --bind /dev/snd "$1" && exec sleep 600 < "$1/${2##*/}"' _ "$work/snd" "$ctl" &
hp=$!
holders+=("$hp")
stdin_is "$hp" "$ctl_rdev" || fail "the bind-mount holder (pid $hp) does not hold $ctl"
echo "its fd's path: $(readlink "/proc/$hp/fd/0")"
release 1 "$hp"
expect_refused "bind-mount ALSA holder" "$hp"
still_bound "bind-mount ALSA holder"
stop "$hp"

echo "-- a regular file named $ctl on a private tmpfs over /dev"
unshare -m sh -c 'mount -t tmpfs tmpfs /dev && mkdir /dev/snd && : > "$1" && exec sleep 600 < "$1"' _ "$ctl" &
hp=$!
holders+=("$hp")
stdin_is "$hp" file || fail "the fake-node holder (pid $hp) does not hold its file"
echo "its fd's path: $(readlink "/proc/$hp/fd/0")"
h=$(gc573_holders "$(readlink -f "$dev")")
if grep -q "^$hp " <<< "$h"; then
	echo "BAD:  the fake node counts as a holder: $(LC_ALL=C tr -cd '[:print:]\n' <<< "$h" | tr '\n' ';')"
	bad=1
else
	echo "ok:   the fake node is no holder"
fi
stop "$hp"

echo "-- ALSA holder that calls itself wireplumber, --yes"
hold "$ctl" python3 -c 'import ctypes, sys, time
f = open(sys.argv[1], "rb")
ctypes.CDLL(None).prctl(15, b"wireplumber", 0, 0, 0)
time.sleep(600)' "$ctl"
renamed "$hp" || fail "the holder did not rename itself"
echo "comm: $(cat "/proc/$hp/comm")"
release 1 "$hp"
expect_refused "fake wireplumber" "$hp"
still_bound "fake wireplumber"
stop "$hp"

if [ -x /usr/bin/pipewire ]; then
	echo "-- ALSA holder that runs another executable mounted over /usr/bin/pipewire, --yes"
	cp "$(command -v sleep)" "$work/fakepw"
	unshare -m sh -c 'mount --bind "$1" /usr/bin/pipewire && exec /usr/bin/pipewire 600 < "$2"' _ "$work/fakepw" "$ctl" &
	hp=$!
	holders+=("$hp")
	stdin_is "$hp" "$ctl_rdev" || fail "the fake pipewire (pid $hp) does not hold $ctl"
	echo "its exe: $(readlink "/proc/$hp/exe"), comm $(cat "/proc/$hp/comm")"
	release 1 "$hp"
	expect_refused "executable mounted over /usr/bin/pipewire" "$hp"
	still_bound "fake pipewire"
	stop "$hp"
else
	echo "-- (no /usr/bin/pipewire: the mounted-over executable is not tried)"
fi

p=$(pgrep -x wireplumber | head -1)
if [ -n "$p" ]; then
	s=$(gc573_sound_server "$p") || s=none
	if [ "$s" = PipeWire ]; then
		echo "ok:   the desktop's wireplumber (pid $p) is PipeWire"
	else
		echo "BAD:  the desktop's wireplumber (pid $p) is not taken for PipeWire ($s)"
		bad=1
	fi
else
	echo "-- (no wireplumber running: the real one is not tried)"
fi

echo "-- video holder with escapes in its comm"
hold "$vdev" python3 -c 'import ctypes, sys, time
f = open(sys.argv[1], "rb")
ctypes.CDLL(None).prctl(15, b"\x1b[2J\x1b]0;x\x07\nfake", 0, 0, 0)
time.sleep(600)' "$vdev"
renamed "$hp" || fail "the holder did not rename itself"
release 0 "$hp"
expect_refused "escape-laden comm" "$hp"
if LC_ALL=C grep -q '[[:cntrl:]]' <<< "$out"; then
	echo "BAD:  control characters reached the output"
	bad=1
else
	echo "ok:   no control characters in the output"
fi
still_bound "video holder"
stop "$hp"

echo "-- a file named like a holder record"
# a path ending in "<newline>1 /dev/videoN": made of directories, as a
# file name cannot hold a /
f="$work/x"$'\n'"1 $vdev"
mkdir -p "${f%/*}"
: > "$f"
hold_open "$f"
h=$(gc573_holders "$(readlink -f "$dev")")
if [ -z "$h" ]; then
	echo "ok:   no holder found"
else
	echo "BAD:  holders found: $(LC_ALL=C tr -cd '[:print:]\n' <<< "$h" | tr '\n' ';')"
	bad=1
fi
stop "$hp"

echo "-- the VFIO check under /proc churn and an early head, set -euo pipefail"
fake=$work/fakedev
mkdir -p "$fake/vfio-dev/vfio0"
cat "/sys/class/video4linux/${vdev#/dev/}/dev" > "$fake/vfio-dev/vfio0/dev"
# a command line of 20000 "guest=" names: grep's output outruns head -1
mapfile -t names < <(seq -f 'guest=vm%g' 20000)
hold "$vdev" python3 -c 'import sys, time
f = open(sys.argv[1], "rb")
time.sleep(600)' "$vdev" "${names[@]}"
vh=$hp
( while :; do for i in $(seq 30); do /bin/true & done; wait; done ) > /dev/null 2>&1 &
churn=$!
holders+=("$churn")
n=$(bash -c 'set -euo pipefail
NAME=gc573
say() { :; }
. "$1"
for i in $(seq 100); do
	u=$(gc573_vfio_user "$2")
	[ "$u" = "process $3 (python3), virtual machine vm1" ] && echo found
done' _ "$cr" "$fake" "$vh" | grep -c '^found$')
stop "$churn"
if [ "$n" = 100 ]; then
	echo "ok:   found the holder 100 times out of 100"
else
	echo "BAD:  found the holder $n times out of 100 (the shell ended, or the check missed it)"
	bad=1
fi
stop "$vh"

echo "-- an i2c-dev node in flight in a unix socket, --yes"
python3 -c 'import os, socket, sys, time
fd = os.open(sys.argv[1], os.O_RDWR)
a, b = socket.socketpair()
socket.send_fds(a, [b"x"], [fd])
os.close(fd)
print("in flight", flush=True)
time.sleep(600)' "$i2c" > "$work/flight.out" 2>&1 &
hp=$!
holders+=("$hp")
for i in $(seq 50); do grep -q 'in flight' "$work/flight.out" && break; sleep 0.1; done
grep -q 'in flight' "$work/flight.out" || { cat "$work/flight.out"; fail "the in-flight holder did not start"; }
h=$(gc573_holders "$(readlink -f "$dev")")
[ -z "$h" ] || echo "note: holders seen: $(tr '\n' ';' <<< "$h")"
release 1 "$hp"
if [ "$rc" = 3 ] && grep -q 'in flight between programs' <<< "$out"; then
	echo "ok:   the unbind did not finish within 10 s: status 3"
else
	echo "BAD:  status $rc (expected 3, the unbind left waiting)"
	bad=1
fi
if why=$(gc573_unbind_pending); then
	echo "ok:   pending: $why"
else
	echo "BAD:  the unbind left waiting does not count as pending"
	bad=1
fi
release 1 "$hp"
if [ "$rc" = 3 ] && [ "$secs" -le 2 ] && grep -q 'has not finished' <<< "$out"; then
	echo "ok:   a second release refused at once: status 3"
else
	echo "BAD:  a second release: status $rc after $secs s (expected 3 at once)"
	bad=1
fi
writer=""
read -r writer _ < "$GC573_UNBIND_PID" 2>/dev/null
mv "$GC573_UNBIND_PID" "$work/unbind.pid.saved" 2>/dev/null
if why=$(gc573_unbind_pending); then
	echo "ok:   without the record, from the card: $why"
else
	echo "BAD:  without the record, the half-unbound card does not count as pending"
	bad=1
fi
stop "$hp"
for i in $(seq 100); do
	{ [ -n "$writer" ] && kill -0 "$writer" 2>/dev/null; } || break
	sleep 0.1
done
if [ -n "$writer" ] && kill -0 "$writer" 2>/dev/null; then
	echo "BAD:  the unbind (pid $writer) still waits 10 s after the holder ended"
	bad=1
elif why=$(gc573_unbind_pending); then
	echo "BAD:  still pending after the unbind finished: $why"
	bad=1
else
	echo "ok:   the unbind finished once the holder ended; nothing pending"
fi

[ "$bad" = 0 ] || fail "card-release.sh took the card, hung, or printed what it should not"
echo "every holder was handled"
