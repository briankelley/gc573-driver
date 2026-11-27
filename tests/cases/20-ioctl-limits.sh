#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Limits on what an opener of the video node can make the kernel hold
# (security review of a0adb1d), with no input (free-running timings):
# - SOURCE_CHANGE subscriptions (F2): the id is the input index, so only 0
#   is accepted; any other id fails with EINVAL (each would otherwise be a
#   subscription of its own). The control event still subscribes.
# - CREATE_BUFS sizes (F1): from the current sizeimage up to the largest
#   image a format can have (1920x1080 XBGR32, 8294400 bytes); a byte more
#   fails with EINVAL, and so does 64 MiB.
# - CREATE_BUFS memory is the caller's (F1, review section 3 test 8): an
#   unprivileged process (nobody, with the node's group) in a memory
#   cgroup limited to GC573_MEMCG_MB (48) MiB asks for 16 buffers of the
#   largest size (132 MB). It must get no more than the limit holds (the
#   request ends early with fewer buffers, or ENOMEM), the cgroup must be
#   charged for the buffers it holds, nothing may be OOM-killed, and the
#   driver's buffer memory must be back to 0 once it closes. Skipped
#   without the cgroup v2 memory controller.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

SIZE_MAX=8294400
memcg_mb=${GC573_MEMCG_MB:-48}
cg=/sys/fs/cgroup/gc573-test

work=$(mktemp -d)
gcc -O2 -Wall -Wextra -o "$work/gc573-sec" "$GC573_TESTS/gc573-sec.c" ||
	fail "cannot build gc573-sec"
sec=$work/gc573-sec

cleanup() {
	if [ -d "$cg" ]; then
		while read -r p; do
			echo "$p" > /sys/fs/cgroup/cgroup.procs 2>/dev/null
		done < "$cg/cgroup.procs"
		rmdir "$cg" 2>/dev/null
	fi
	gc573_loaded && gc573_unload
	rm -rf "$work"
}

gc573_load || fail "insmod failed"
trap cleanup EXIT
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

# the driver's buffer memory (debugfs "mem") is all 0
mem_zero() {
	local m
	m=$(grep '^mem (live' "$(gc573_debugfs)")
	echo "$m"
	[ -z "$(echo "${m#*:}" | tr ' ' '\n' | grep -E '^[0-9]+$' | grep -vx 0)" ]
}

echo "-- SOURCE_CHANGE subscriptions"
expect ok subscribe -t source_change -i 0
expect EINVAL subscribe -t source_change -i 1
expect EINVAL subscribe -t source_change -i 4294967295
expect ok subscribe -t ctrl

echo "-- CREATE_BUFS sizes"
expect ok createbufs
expect ok createbufs -s "$SIZE_MAX"
expect EINVAL createbufs -s $((SIZE_MAX + 1))
expect EINVAL createbufs -s $((64 << 20))
mem_zero || { echo "BAD:  buffer memory not back to 0"; bad=1; }

echo "-- CREATE_BUFS in a ${memcg_mb} MiB memory cgroup, as nobody"
if ! grep -qw memory /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
	echo "no cgroup v2 memory controller: part skipped"
else
	limit=$((memcg_mb << 20))
	rmdir "$cg" 2>/dev/null
	mkdir "$cg" || fail "cannot create $cg"
	echo "$limit" > "$cg/memory.max" || fail "cannot set memory.max"
	gid=$(stat -c %g "$vdev")
	coproc HOLD {
		echo "$BASHPID" > "$cg/cgroup.procs" &&
			exec setpriv --reuid=65534 --regid="$gid" --clear-groups \
				"$sec" createbufs -d "$vdev" -s "$SIZE_MAX" -n 16 -k
	}
	hold_pid=$HOLD_PID
	read -r -t 60 line <&"${HOLD[0]}"
	echo "$line"
	granted=0
	case $line in
	*" rc=0 "*)
		granted=${line##*granted=}
		granted=${granted%% *}
		read -r -t 10 held <&"${HOLD[0]}"
		[ "$held" = held ] || { echo "BAD:  no 'held' from gc573-sec"; bad=1; }
		;;
	*errno=ENOMEM) ;;
	*) echo "BAD:  unexpected result"; bad=1 ;;
	esac
	cur=$(cat "$cg/memory.current")
	peak=$(cat "$cg/memory.peak" 2>/dev/null || echo -)
	events=$(tr '\n' ' ' < "$cg/memory.events")
	exec {HOLD[1]}>&-
	wait "$hold_pid"
	rc=$?
	held_bytes=$((granted * SIZE_MAX))
	echo "granted $granted buffer(s) = $held_bytes bytes; cgroup: limit $limit current $cur peak $peak; events: $events; gc573-sec exit $rc"
	[ "$held_bytes" -le "$limit" ] ||
		{ echo "BAD:  the buffers exceed the cgroup's limit (not charged to it)"; bad=1; }
	[ "$cur" -ge "$held_bytes" ] ||
		{ echo "BAD:  the cgroup is charged less than the buffers it holds"; bad=1; }
	[ "$granted" -gt 0 ] ||
		{ echo "BAD:  not even one buffer fits the limit"; bad=1; }
	case $events in
	*"oom_kill 0"*) ;;
	*) echo "BAD:  a process was OOM-killed"; bad=1 ;;
	esac
	[ "$rc" = 0 ] || { echo "BAD:  gc573-sec did not exit normally"; bad=1; }
	rmdir "$cg" || echo "warning: cannot remove $cg"
	mem_zero || { echo "BAD:  buffer memory not back to 0"; bad=1; }
fi

[ "$bad" = 0 ] || fail "an ioctl limit did not hold"
echo "every limit held"
