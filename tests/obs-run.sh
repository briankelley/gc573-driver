#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Start or stop OBS in the dev VM for the OBS checks (tests/live.sh steps
# obs, obsav, obschange). Run as the desktop user (dev) over ssh.
#   start  write a minimal configuration on first use (no first-run wizard,
#          profile and scene collection "gc573", obs-websocket on port 4455
#          without a password), clear OBS's run markers, set the recording
#          format, start OBS on the desktop (DISPLAY=:0) and wait for the
#          websocket
#   OBS starts with --multi, in both modes. OBS 32 has no
#          --disable-shutdown-check: at its start it takes any run marker
#          (~/.config/obs-studio/.sentinel/run_*) other than its own for an
#          unclean shutdown and waits in its crash dialog, a window on the
#          desktop, until someone answers it. It writes its own marker, and
#          a clean exit removes all of them. With --multi it neither reads
#          nor writes them (frontend/utility/CrashHandler.cpp). So a test
#          OBS that crashes, or is killed, leaves nothing that stops the
#          next start, the user's or ours, and the user's markers stay as
#          they are (tests/obs-run-check.sh)
#   GC573_OBS_RECFORMAT: Simple output's recording format (RecFormat2),
#          default hybrid_mp4 (OBS 32's default). OBS picks the recording
#          output when it loads the profile: hybrid_mp4 and hybrid_mov are
#          OBS's own muxer, in OBS's process; mkv and the other ffmpeg
#          formats run the obs-ffmpeg-mux helper, which inherits OBS's file
#          descriptors, the V4L2 device's too (OBS opens it without
#          O_CLOEXEC). Changing RecFormat2 while OBS runs (obs-websocket
#          SetProfileParameter) changes only the file name's extension.
#   stop   SIGTERM, then SIGKILL after 20 s; clears the run markers
#   --keep-config: an OBS whose configuration is the user's (the host, with
#          the profile and scene collection "gc573" set up and obs-websocket
#          on with its password; tests/obsws.py reads it): nothing in
#          OBS's configuration is written. start refuses unless the gc573
#          profile records in GC573_OBS_RECFORMAT's format, and starts OBS
#          minimized to the tray (--minimize-to-tray: no preview is drawn,
#          which on a slow GPU makes OBS lag while it records), then checks
#          that no OBS window shows. An OBS that runs already is used as it
#          is if its websocket answers, and then stop leaves it running:
#          stop ends only the OBS that start started (pid file).
# OBS's log: ~/.config/obs-studio/logs/ (newest file).
# Usage: obs-run.sh start|stop [--keep-config]
set -u
c=$HOME/.config/obs-studio
pidf=${XDG_RUNTIME_DIR:-/tmp}/gc573-obs-run.pid
if [ "${2:-}" = --keep-config ]; then
	fmt=${GC573_OBS_RECFORMAT:-hybrid_mp4}
	case ${1:-} in
	start)
		if pgrep -x obs > /dev/null; then
			ss -ltn | grep -q ':4455 ' || { echo "OBS runs without its websocket: not starting another"; exit 1; }
			rm -f "$pidf"
			echo "OBS running (pid $(pgrep -x obs | tr '\n' ' ')): used as it is, and left running"
			exit 0
		fi
		have=$(awk -F= '/^\[/ { sec = ($0 == "[SimpleOutput]") } sec && $1 == "RecFormat2" { print $2 }' \
			"$c/basic/profiles/gc573/basic.ini" 2>/dev/null)
		[ "${have:-hybrid_mp4}" = "$fmt" ] ||
			{ echo "profile gc573 records in ${have:-?}, not $fmt: not changed here"; exit 1; }
		# The ALSA source must name the card so that alsa-lib opens it
		# alone: by a path or an index. By the card's id (hw:CARD=GC573)
		# alsa-lib opens the control node of every card before it to compare
		# ids (snd_card_get_index), a webcam's among them, and this OBS is
		# ours (tools/testsrc/camwatch.py)
		bad=$(python3 - "$c/basic/scenes/gc573.json" <<'EOF'
import json, re, sys
for s in json.load(open(sys.argv[1])).get('sources', []):
    if s.get('id') == 'alsa_input_capture':
        st = s.get('settings', {})
        pcm = st.get('custom_pcm') if st.get('device_id') == '__custom__' else st.get('device_id')
        m = re.match(r'^(?:plug)?hw:(?:CARD=)?([^,]+)', pcm or '')
        if not (m and (m.group(1).isdigit() or m.group(1).startswith('/'))):
            print(f'"{s.get("name")}" on {pcm}')
EOF
)
		[ -z "$bad" ] || { echo "scene collection gc573: ALSA source $bad: by the card's id alsa-lib opens the control node of every card before it; set hw:CARD=/dev/snd/by-path/pci-<address>,DEV=0. Not started"; exit 1; }
		# OBS 32.2 with NVIDIA 470 can crash while it starts: its graphics
		# thread's getenv() in libnvidia-eglcore races the frontend-tools
		# plugin's Python start (core dump of 2026-11-26 03:37:22Z). One
		# more try then (with --multi the crash leaves no run marker)
		for try in 1 2; do
			DISPLAY=${DISPLAY:-:0} setsid obs --multi --minimize-to-tray --disable-shutdown-check \
				--disable-missing-files-check --profile gc573 --collection gc573 \
				> "${XDG_RUNTIME_DIR:-/tmp}/gc573-obs-stdout.txt" 2>&1 < /dev/null &
			echo $! > "$pidf"
			for _ in $(seq 120); do
				if ss -ltn | grep -q ':4455 '; then
					sleep 3
					vis=$(DISPLAY=${DISPLAY:-:0} xdotool search --onlyvisible --pid "$(cat "$pidf")" 2>/dev/null | wc -l)
					echo "OBS started minimized to the tray (pid $(cat "$pidf"), profile gc573, recording format $fmt; $vis windows visible)"
					[ "$vis" = 0 ] || { echo "an OBS window shows: the preview would be drawn"; exit 1; }
					exit 0
				fi
				kill -0 "$(cat "$pidf")" 2>/dev/null || break
				sleep 0.5
			done
			kill -0 "$(cat "$pidf")" 2>/dev/null && { echo "OBS did not open its websocket in 60 s"; exit 1; }
			echo "OBS (pid $(cat "$pidf")) ended while starting, attempt $try (its log: ~/.config/obs-studio/logs/)"
		done
		rm -f "$pidf"
		exit 1
		;;
	stop)
		[ -f "$pidf" ] || { echo "OBS left running (not started by obs-run.sh)"; exit 0; }
		pid=$(cat "$pidf")
		rm -f "$pidf"
		[ "$(ps -o comm= -p "$pid" 2>/dev/null)" = obs ] || { echo "OBS (pid $pid) has stopped"; exit 0; }
		kill -TERM "$pid"
		for _ in $(seq 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
		kill -0 "$pid" 2>/dev/null && { kill -KILL "$pid"; echo "OBS killed"; }
		echo "OBS stopped"
		exit 0
		;;
	esac
fi
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
	fmt=${GC573_OBS_RECFORMAT:-hybrid_mp4}
	for f in "$c"/basic/profiles/*/basic.ini; do
		[ -f "$f" ] || continue
		awk -v v="$fmt" '
			/^\[/ { if (sec && !done) { print "RecFormat2=" v; done = 1 } sec = ($0 == "[SimpleOutput]") }
			sec && /^RecFormat2=/ { if (!done) print "RecFormat2=" v; done = 1; next }
			{ print }
			END { if (!done) { if (!sec) print "[SimpleOutput]"; print "RecFormat2=" v } }' "$f" > "$f.new" &&
			mv "$f.new" "$f"
	done
	DISPLAY=:0 setsid obs --multi --minimize-to-tray --disable-shutdown-check \
		--disable-missing-files-check --profile gc573 --collection gc573 \
		> /tmp/obs-stdout.txt 2>&1 < /dev/null &
	for _ in $(seq 120); do
		ss -ltn | grep -q ':4455 ' && { sleep 2; echo "OBS started (recording format $fmt)"; exit 0; }
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
	echo "usage: obs-run.sh start|stop [--keep-config]" >&2; exit 2 ;;
esac
