#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Limits on what an opener of the video node can make the kernel hold
# (security review of a0adb1d), with no input (free-running timings):
# - SOURCE_CHANGE subscriptions (F2): the id is the input index, so only 0
#   is accepted; any other id fails with EINVAL (each would otherwise be a
#   subscription of its own). The control event still subscribes.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

work=$(mktemp -d)
gcc -O2 -Wall -Wextra -o "$work/gc573-sec" "$GC573_TESTS/gc573-sec.c" ||
	fail "cannot build gc573-sec"
sec=$work/gc573-sec

gc573_load || fail "insmod failed"
trap 'gc573_loaded && gc573_unload; rm -rf "$work"' EXIT
vdev=$(gc573_video_dev) || fail "no video device"
gc573_input_off "$vdev"
bad=0

# $1: expected "ok" or an errno name; the rest: gc573-sec arguments
expect() {
	local want=$1 out got
	shift
	out=$("$sec" "$@" -d "$vdev")
	case $out in
	*" rc=0"*) got=ok ;;
	*errno=*) got=${out##*errno=} ;;
	*) got="?" ;;
	esac
	if [ "$got" = "$want" ]; then
		echo "ok:   $out"
	else
		echo "BAD:  $out (expected $want)"
		bad=1
	fi
}

echo "-- SOURCE_CHANGE subscriptions"
expect ok subscribe -t source_change -i 0
expect EINVAL subscribe -t source_change -i 1
expect EINVAL subscribe -t source_change -i 4294967295
expect ok subscribe -t ctrl

[ "$bad" = 0 ] || fail "an ioctl limit did not hold"
echo "every limit held"
