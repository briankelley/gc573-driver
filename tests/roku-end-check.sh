#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Offline check of live.sh's Roku-mode run end (no Roku, no card, no
# network): its functions roku_serve_start, roku_serve_stop, roku_play,
# roku_key, roku_end and roku_go, taken from tests/live.sh (or GC573_LIVE), with
# ecp.py and serve.py replaced by stubs. As in live.sh, the steps run in a
# subshell piped to tee and the EXIT trap in the shell above it. Checks:
# - the run ends: the server (a stub that would sleep 600 s, writing to
#   stdout and stderr) does not hold tee's pipe open;
# - the trap stops the server, which is no child of its shell;
# - the trap runs stop-ours after a play (with the go), and not without
#   a play or without the go;
# - the trap sends Home when the steps' PowerOff left the Roku asleep, and
#   not after their own Home;
# - the run's directory (ROKU_RUN) is removed.
# Usage: tests/roku-end-check.sh   (PASS/FAIL lines; exit 1 on a failure)
set -u
here=$(cd "$(dirname "$0")" && pwd)
LIVE=${GC573_LIVE:-$here/live.sh}

if [ "${1:-}" = --child ]; then
	# shellcheck source=/dev/null
	. <(for f in roku_go roku_serve_start roku_serve_stop roku_play roku_key roku_end; do
		sed -n "/^$f() {/,/^}/p" "$LIVE"
	done)
	ecp() { echo "ecp $*" >> "$STATE/ecp.log"; }
	ROOT=$STATE/root OBSSOAK_SECS=10 ROKU_URL_FILE="" roku_serve_pid="" roku_served="" roku_halt=0
	ROKU_RUN=$(mktemp -d "$STATE/run.XXXXXX")
	echo "$ROKU_RUN" > "$STATE/run-dir"
	trap 'roku_end' EXIT
	{
		roku_serve_start "$STATE/x.mp4" || echo "server did not start"
		[ "$2" = 0 ] || roku_play
		[ "$3" = 0 ] || roku_key PowerOff
		[ "$3" != 2 ] || roku_key Home
		echo "steps done"
	} 2>&1 | tee "$STATE/tee.out"
	exit 0
fi

fails=0
check() {	# name, condition result, detail
	if [ "$2" = 0 ]; then echo "PASS $1 $3"; else echo "FAIL $1 $3"; fails=$((fails + 1)); fi
}
STATE=$(mktemp -d)
export STATE
trap 'rm -rf "$STATE"' EXIT
mkdir -p "$STATE/root/tools/roku"
cat > "$STATE/root/tools/roku/serve.py" <<'PY'
import os
import sys
import time
url_file = sys.argv[sys.argv.index('--url-file') + 1]
open(os.path.join(os.environ['STATE'], 'server.pid'), 'w').write(str(os.getpid()))
open(os.path.join(os.environ['STATE'], 'url-file'), 'w').write(url_file)
print('stub server: a line on stdout', flush=True)
print('stub server: a line on stderr', file=sys.stderr, flush=True)
open(url_file, 'w').write('http://127.0.0.1:9/x.mp4\n')
time.sleep(600)
PY
# go, played, sleep (0: none; 1: PowerOff; 2: PowerOff, then Home)
for c in "1 1 0" "1 0 0" "0 1 0" "1 0 1" "1 0 2"; do
	read -r go played sleep <<< "$c"
	rm -f "$STATE/ecp.log" "$STATE/server.pid" "$STATE/run-dir" "$STATE/url-file"
	t0=$(date +%s)
	GC573_ROKU_GO=$go timeout 30 "$0" --child "$played" "$sleep" > /dev/null 2>&1
	rc=$? dt=$(($(date +%s) - t0))
	pid=$(cat "$STATE/server.pid" 2>/dev/null)
	run=$(cat "$STATE/run-dir" 2>/dev/null)
	stops=$(grep -c 'ecp stop-ours' "$STATE/ecp.log" 2>/dev/null)
	want=$([ "$go$played" = 11 ] && echo 1 || echo 0)
	homes=$(grep -c 'ecp key Home' "$STATE/ecp.log" 2>/dev/null)
	# the step's own Home, or the trap's after a PowerOff alone
	hwant=$([ "$sleep" = 0 ] && echo 0 || echo 1)
	check "end-go$go-played$played-sleep$sleep" "$([ "$rc" = 0 ] && [ "$dt" -lt 15 ] && [ -n "$pid" ] &&
		! kill -0 "$pid" 2>/dev/null && [ "${stops:-0}" = "$want" ] && [ "${homes:-0}" = "$hwant" ] &&
		[ -n "$run" ] && [ ! -e "$run" ]; echo $?)" \
		"(exit $rc after $dt s; server ${pid:+$( kill -0 "$pid" 2>/dev/null && echo 'still running' || echo stopped)}; stop-ours ${stops:-0} times, want $want; Home ${homes:-0} times, want $hwant; run dir $([ -n "$run" ] && [ ! -e "$run" ] && echo removed || echo left))"
	[ -z "$pid" ] || kill "$pid" 2>/dev/null
	# the real server removes its URL file at its end; the stub does not
	[ ! -s "$STATE/url-file" ] || rm -f "$(cat "$STATE/url-file")"
done
echo "FAILS $fails"
[ "$fails" = 0 ]
