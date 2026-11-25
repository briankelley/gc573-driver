#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Start or stop OBS in the dev VM for the OBS checks (tests/live.sh steps
# obs, obsav, obschange). Run as the desktop user (dev) over ssh.
#   start  write a minimal configuration on first use (no first-run wizard,
#          profile and scene collection "gc573", obs-websocket on port 4455
#          without a password), clear OBS's run markers (after a kill OBS
#          would otherwise wait in its "unclean shutdown" dialog), start OBS
#          on the desktop (DISPLAY=:0) and wait for the websocket
#   stop   SIGTERM, then SIGKILL after 20 s; clears the run markers
# OBS's log: ~/.config/obs-studio/logs/ (newest file).
# Usage: obs-run.sh start|stop
set -u
c=$HOME/.config/obs-studio
case ${1:-} in
start)
	if pgrep -x obs > /dev/null && ss -ltn | grep -q ':4455 '; then
		echo "OBS running"; exit 0
	fi
	pkill -x obs 2>/dev/null; sleep 1
	mkdir -p "$c/plugin_config/obs-websocket"
	for f in global.ini user.ini; do
		[ -f "$c/$f" ] || printf '[General]\nFirstRun=false\nConfirmOnExit=false\n\n[Basic]\nProfile=gc573\nProfileDir=gc573\nSceneCollection=gc573\nSceneCollectionFile=gc573\n' > "$c/$f"
	done
	printf '%s\n' '{"alerts_enabled": false, "auth_required": false, "first_load": false, "server_enabled": true, "server_password": "", "server_port": 4455}' \
		> "$c/plugin_config/obs-websocket/config.json"
	rm -f "$c"/.sentinel/run_*
	DISPLAY=:0 setsid obs --minimize-to-tray --disable-shutdown-check \
		--disable-missing-files-check --profile gc573 --collection gc573 \
		> /tmp/obs-stdout.txt 2>&1 < /dev/null &
	for _ in $(seq 120); do
		ss -ltn | grep -q ':4455 ' && { sleep 2; echo "OBS started"; exit 0; }
		sleep 0.5
	done
	echo "OBS did not open its websocket in 60 s"; tail -5 /tmp/obs-stdout.txt; exit 1
	;;
stop)
	pkill -TERM -x obs 2>/dev/null
	for _ in $(seq 40); do pgrep -x obs > /dev/null || break; sleep 0.5; done
	pgrep -x obs > /dev/null && { pkill -KILL -x obs; echo "OBS killed"; }
	rm -f "$c"/.sentinel/run_*
	echo "OBS stopped"
	;;
*)
	echo "usage: obs-run.sh start|stop" >&2; exit 2 ;;
esac
