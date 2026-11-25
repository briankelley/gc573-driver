#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# avsync.sh must leave the host's stored audio settings alone (host only).
# WirePlumber stores a card profile, the default sink and a sink's volume
# whenever a client sets them with pactl (set-card-profile, set-default-sink,
# set-sink-volume, set-sink-mute: PipeWire's Profile or Route param with
# save=true, or the default.configured.* metadata); avsync.sh switches the
# NVIDIA HDMI audio card's profile for a session only (pw-cli set-param ...
# save: false) and touches the default sink and the sink's volume only when
# they differ.
#
# A silent session (--amplitude 0) of AVSYNC (default: tools/testsrc/avsync.sh)
# is started and stopped with pactl and pw-cli wrapped, to log every call:
#   state-pactl     no storing pactl call (the default sink is the user's,
#                   the sink is at 100 % and unmuted, the profile is active)
#   state-param     the card's Profile param, read back during the session,
#                   has save=false
#   state-files     ~/.local/state/wireplumber/default-profile and
#                   default-nodes have the same content afterwards
# --transient: also with the card's profile off at the start (set with
# save=false, as WirePlumber's own policy sets it): avsync.sh must switch it
# with save=false only, and --off must put "off" back the same way; the
# profile active at the start is put back at the end (save=false).
#   state-transient-set, state-transient-off, state-transient-files
# tools/testsrc/guard.py watches the run. Needs the capture card's ELD on the
# NVIDIA HDMI audio card (gc573 loaded in the VM, OUTPUT on).
# Usage: tools/testsrc/state-check.sh [--transient] [AVSYNC]
set -uo pipefail
export DISPLAY=${DISPLAY:-:0} XAUTHORITY=${XAUTHORITY:-$HOME/.Xauthority}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
here=$(cd "$(dirname "$0")" && pwd)
transient=0
[ "${1:-}" != --transient ] || { transient=1; shift; }
avsync=${1:-$here/avsync.sh}
st=$HOME/.local/state/wireplumber
tmp=$(mktemp -d /tmp/gc573-state-check.XXXXXX)
log=$tmp/calls.log
fails=0

for t in pactl pw-cli; do
	real=$(command -v $t) || { echo "no $t"; exit 2; }
	printf '#!/bin/sh\necho "%s $*" >> "%s"\nexec %s "$@"\n' "$t" "$log" "$real" > "$tmp/$t"
	chmod +x "$tmp/$t"
done
result() { echo "RESULT $1 $2 ($3)"; [ "$2" = PASS ] || fails=$((fails + 1)); }
sums() { (cd "$st" && sha256sum default-profile default-nodes 2>/dev/null); }
addr=$(lspci -D -d 10de: | awk '/Audio/{print $1; exit}')
card=alsa_card.pci-${addr//:/_}
devid() {
	pw-cli ls Device 2>/dev/null | awk -v n="\"$card\"" '$1 == "id" { id = $2; sub(",", "", id) }
		$1 == "device.name" && $3 == n { print id; exit }'
}
# the active profile's name and save flag: "NAME SAVE"
profile_param() {
	pw-cli enum-params "$(devid)" Profile 2>/dev/null | awk '
		/Profile:name/ { getline; n = $2; gsub(/"/, "", n) }
		/Profile:save/ { getline; s = $2 } END { print n, s }'
}
set_transient() {	# profile NAME, save=false
	local idx
	idx=$(pw-cli enum-params "$(devid)" EnumProfile 2>/dev/null | awk -v n="\"$1\"" '
		/Profile:index/ { getline; i = $2 } /Profile:name/ { getline; if ($2 == n) { print i; exit } }')
	[ -n "$idx" ] && pw-cli set-param "$(devid)" Profile "{ index: $idx, save: false }" >/dev/null
}
storing='^pactl (set-card-profile|set-default-sink|set-default-source|set-sink-volume|set-sink-mute|set-sink-port)'

python3 "$here/guard.py" --pid $$ --log "$tmp/guard.log" &
gpid=$!
trap '"$avsync" --off >/dev/null 2>&1; kill $gpid 2>/dev/null; cat "$tmp/guard.log" 2>/dev/null | grep -E "BREACH|end:"; rm -rf "$tmp"' EXIT
sleep 1
s0=$(sums)
p0=$(profile_param)
echo "card $card, PipeWire device $(devid); active profile and save flag at the start: $p0"

: > "$log"
PATH=$tmp:$PATH "$avsync" --amplitude 0 >/dev/null 2>&1
rc=$?
p1=$(profile_param)
PATH=$tmp:$PATH "$avsync" --off >/dev/null 2>&1
st_calls=$(grep -E "$storing" "$log" | sort | uniq -c | sed 's/^ *//' | paste -sd';')
result state-pactl "$([ $rc = 0 ] && [ -z "$st_calls" ] && echo PASS || echo FAIL)" \
	"avsync.sh exit $rc; storing pactl calls: ${st_calls:-none}"
result state-param "$([ "${p1#* }" = false ] && echo PASS || echo FAIL)" \
	"during the session: profile ${p1% *}, save=${p1#* }"
result state-files "$([ "$(sums)" = "$s0" ] && echo PASS || echo FAIL)" \
	"default-profile and default-nodes $([ "$(sums)" = "$s0" ] && echo unchanged || echo CHANGED)"

if [ $transient = 1 ]; then
	set_transient off
	sleep 0.5
	: > "$log"
	PATH=$tmp:$PATH "$avsync" --amplitude 0 >/dev/null 2>&1
	rc=$?
	p1=$(profile_param)
	PATH=$tmp:$PATH "$avsync" --off >/dev/null 2>&1
	sleep 0.5
	p2=$(profile_param)
	sets=$(grep -E '^pw-cli set-param' "$log" | sed 's/^pw-cli set-param [0-9]* //' | paste -sd';')
	st_calls=$(grep -E "$storing" "$log" | sort | uniq -c | sed 's/^ *//' | paste -sd';')
	result state-transient-set "$([ $rc = 0 ] && [ "$p1" = "${p0% *} false" ] && [ -z "$st_calls" ] &&
		! grep -E '^pw-cli set-param' "$log" | grep -qv 'save: false' && echo PASS || echo FAIL)" \
		"from off: avsync.sh exit $rc, during the session $p1; pw-cli set-param: ${sets:-none}; storing pactl calls: ${st_calls:-none}"
	result state-transient-off "$([ "$p2" = "off false" ] && echo PASS || echo FAIL)" \
		"after --off: $p2"
	set_transient "${p0% *}"
	sleep 0.5
	result state-transient-files "$([ "$(sums)" = "$s0" ] && echo PASS || echo FAIL)" \
		"default-profile and default-nodes $([ "$(sums)" = "$s0" ] && echo unchanged || echo CHANGED); profile put back: $(profile_param)"
fi
echo "SUMMARY fail=$fails"
[ $fails = 0 ]
