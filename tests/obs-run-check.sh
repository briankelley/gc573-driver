#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Checks tests/obs-run.sh start/stop --keep-config against a stand-in for
# OBS 32.2's start (frontend/utility/CrashHandler.cpp, OBSApp.cpp):
#   - without --multi, OBS takes any run marker
#     (~/.config/obs-studio/.sentinel/run_*) other than its own for an
#     unclean shutdown and waits in its crash dialog, a window on the
#     desktop, before its websocket opens; it then writes its own marker,
#     and a clean exit removes every marker;
#   - with --multi it neither reads nor writes them.
# --disable-shutdown-check, which older OBS had, is gone in OBS 32.
# Cases:
#   stale  a marker an earlier OBS left: the start opens the websocket with
#          no crash dialog, and the marker stays as it was (the user's)
#   crash  the first OBS ends while starting (as at 2026-11-26 03:37:22Z):
#          the second try opens the websocket with no crash dialog, and no
#          marker is left
# Needs ss and python3. SKIP while an OBS runs or port 4455 is taken.
# HOME and XDG_RUNTIME_DIR point at a scratch directory: the real
# configuration is not touched.
# Usage: obs-run-check.sh [OBS_RUN]   (default: obs-run.sh next to it)
set -u
here=$(cd "$(dirname "$0")" && pwd)
run=${1:-$here/obs-run.sh}
fails=0
result() {
	printf 'RESULT %-12s %s %s\n' "$1" "$2" "$3"
	[ "$2" = FAIL ] && fails=$((fails + 1))
	return 0
}
if pgrep -x obs > /dev/null || ss -ltn | grep -q ':4455 '; then
	result obs-run SKIP "(an OBS runs, or port 4455 is taken)"
	exit 0
fi
t=$(mktemp -d /tmp/obs-run-check.XXXXXX)
cfg=$t/.config/obs-studio
mkdir -p "$t/bin" "$t/run" "$cfg/.sentinel" "$cfg/basic/scenes"
echo '{"sources": []}' > "$cfg/basic/scenes/gc573.json"
cat > "$t/bin/obs" << 'EOF'
#!/bin/bash
# stand-in for OBS 32.2's start (obs-run-check.sh)
s=$HOME/.config/obs-studio/.sentinel
multi=0
for a in "$@"; do
	case $a in --multi | -m) multi=1 ;; esac
done
n=$(($(cat "$HOME/starts" 2> /dev/null || echo 0) + 1))
echo "$n" > "$HOME/starts"
echo "start $n: $*" >> "$HOME/obs.log"
mkdir -p "$s"
if [ $multi = 0 ]; then
	if compgen -G "$s/run_*" > /dev/null; then
		echo "start $n: Crash or unclean shutdown detected (crash dialog)" >> "$HOME/obs.log"
		sleep 600 &
		trap 'kill $!; exit 0' TERM
		wait
		exit 0
	fi
	: > "$s/run_$(cat /proc/sys/kernel/random/uuid)"
fi
if [ "${OBS_CHECK_CRASH_FIRST:-0}" = 1 ] && [ "$n" = 1 ]; then
	echo "start $n: crashed while starting" >> "$HOME/obs.log"
	exit 139
fi
python3 -c 'import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 4455))
s.listen(1)
time.sleep(600)' &
py=$!
trap 'kill $py; [ $multi = 1 ] || rm -f "$s"/run_*; echo "start $n: clean exit" >> "$HOME/obs.log"; exit 0' TERM
wait
EOF
chmod +x "$t/bin/obs"
cleanup() {
	pkill -TERM -f "^/bin/bash $t/bin/obs" 2> /dev/null
	sleep 0.5
	rm -rf "$t"
}
trap cleanup EXIT
obsrun() {
	env HOME="$t" XDG_RUNTIME_DIR="$t/run" PATH="$t/bin:$PATH" "$@" bash "$run" "$cmd" --keep-config 2>&1
}
markers() { (cd "$cfg/.sentinel" && ls -A); }

# stale: a marker an earlier OBS left
: > "$cfg/.sentinel/run_00000000-0000-0000-0000-000000000000"
m0=$(markers)
cmd=start
out=$(obsrun)
echo "$out" | sed 's/^/  start: /'
cmd=stop
stop=$(obsrun)
echo "$stop" | sed 's/^/  stop: /'
sed 's/^/  stand-in: /' "$t/obs.log"
m1=$(markers)
if grep -q "crash dialog" "$t/obs.log" || ! grep -q "^OBS started" <<< "$out"; then
	result stale FAIL "(an earlier OBS's run marker: $(grep -q 'crash dialog' "$t/obs.log" && echo 'OBS waited in its crash dialog' || echo 'no start'))"
elif [ "$m1" != "$m0" ]; then
	result stale FAIL "(run markers before the start: ${m0:-none}; after the stop: ${m1:-none})"
else
	result stale PASS "(an earlier OBS's run marker: started without the crash dialog, the marker left as it was)"
fi

# crash: the first OBS ends while starting
rm -f "$cfg"/.sentinel/run_* "$t/obs.log" "$t/starts"
cmd=start
out=$(obsrun OBS_CHECK_CRASH_FIRST=1)
echo "$out" | sed 's/^/  start: /'
cmd=stop
stop=$(obsrun)
echo "$stop" | sed 's/^/  stop: /'
sed 's/^/  stand-in: /' "$t/obs.log"
m1=$(markers)
if grep -q "crash dialog" "$t/obs.log" || ! grep -q "^OBS started" <<< "$out"; then
	result crash FAIL "(OBS ended while starting: the next try $(grep -q 'crash dialog' "$t/obs.log" && echo 'waited in its crash dialog' || echo 'did not start'))"
elif [ -n "$m1" ]; then
	result crash FAIL "(run markers left: $m1)"
else
	result crash PASS "(OBS ended while starting: the second try started without the crash dialog, no marker left)"
fi
[ $fails = 0 ]
