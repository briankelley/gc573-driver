#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# tools/card-release.sh, which install.sh and uninstall.sh use to take the
# card from a loaded gc573 (security review of a0adb1d, F6 and F7):
# - an i2c-dev holder of bus 1 and an ALSA holder of the control node
#   (sleep, as any user can) are refused even with --yes (status 1), and
#   the card stays bound: an unbind would wait for them;
# - a holder that names itself "wireplumber" is not PipeWire (that is by
#   executable) and is refused the same way;
# - a video holder whose comm is full of terminal escapes is named with
#   printable characters only;
# - a process holding a file named "x<newline>1 /dev/videoN" is no holder.
# Each release runs bounded: before these fixes some of them unbind and
# block until the holder closes, so after 30 s the case kills the holder
# (which ends the unbind) and fails.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

cr=$GC573_TESTS/../tools/card-release.sh
[ -f "$cr" ] || skip "no tools/card-release.sh next to tests/ (tools/vmbuild.sh syncs it)"
NAME=$GC573_MOD
say() { printf '%s\n' "$*"; }
# shellcheck source=tools/card-release.sh
. "$cr"

dev=/sys/bus/pci/devices/$GC573_BDF
work=$(mktemp -d)
holders=()

cleanup() {
	for p in "${holders[@]}"; do kill "$p" 2>/dev/null; done
	wait 2>/dev/null
	gc573_loaded && gc573_unload
	rm -rf "$work"
}

gc573_load || fail "insmod failed"
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
bad=0

# Start a holder: "$@" runs in the background; its pid in $hp
hold() {
	"$@" &
	hp=$!
	holders+=("$hp")
	sleep 0.5
}

# gc573_release $1 in the background, at most 30 s; then the holder $2 is
# killed (it ends an unbind that waits for it). Output in $out, status $rc
release() {
	local i
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
	gc573_loaded || gc573_load
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
hold sleep 600 < "$i2c"
release 1 "$hp"
expect_refused "i2c-dev holder" "$hp"
still_bound "i2c-dev holder"
stop "$hp"

echo "-- ALSA control holder, --yes"
hold sleep 600 < "$ctl"
release 1 "$hp"
expect_refused "ALSA holder" "$hp"
still_bound "ALSA holder"
stop "$hp"

echo "-- ALSA holder that calls itself wireplumber, --yes"
hold python3 -c 'import ctypes, sys, time
f = open(sys.argv[1], "rb")
ctypes.CDLL(None).prctl(15, b"wireplumber", 0, 0, 0)
time.sleep(600)' "$ctl"
echo "comm: $(cat "/proc/$hp/comm")"
release 1 "$hp"
expect_refused "fake wireplumber" "$hp"
still_bound "fake wireplumber"
stop "$hp"

echo "-- video holder with escapes in its comm"
hold python3 -c 'import ctypes, sys, time
f = open(sys.argv[1], "rb")
ctypes.CDLL(None).prctl(15, b"\x1b[2J\x1b]0;x\x07\nfake", 0, 0, 0)
time.sleep(600)' "$vdev"
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
f="$work/x"$'\n'"1 $vdev"
: > "$f"
hold sleep 600 < "$f"
h=$(gc573_holders "$(readlink -f "$dev")")
if [ -z "$h" ]; then
	echo "ok:   no holder found"
else
	echo "BAD:  holders found: $(LC_ALL=C tr -cd '[:print:]\n' <<< "$h" | tr '\n' ';')"
	bad=1
fi
stop "$hp"

[ "$bad" = 0 ] || fail "card-release.sh took the card, hung, or printed what it should not"
echo "every holder was handled"
