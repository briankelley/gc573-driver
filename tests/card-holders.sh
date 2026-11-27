#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# The processes that hold a GC573's nodes open (video, media, ALSA,
# i2c-dev), by tools/card-release.sh's scan of open files (by device
# number, O_PATH descriptors left out): every one but a sound server's own
# (PipeWire, PulseAudio keep the ALSA control node open by design and let
# go when the card goes), and a sound server too while it streams the
# card's audio. For the end of a test run (tests/live.sh): a test process
# that outlives its run with a node open, as tests/obsbridge.py did in
# the VM (2d533cf), holds the module and the card from the next unload,
# unbind and dead case.
# Usage: sudo tests/card-holders.sh [BDF]   (default: every GC573)
#   One line per holder, "BDF: NAME (pid P): NODE,...". Exit 0 none, 1
#   some, 2 the scan did not finish, 3 no GC573.
set -u
export LC_ALL=C
here=$(cd "$(dirname "$0")" && pwd)
NAME=gc573
say() { printf '%s\n' "$*"; }
# next to this file where live.sh puts both (its work directory), else
# the tree's
if [ -f "$here/card-release.sh" ]; then
	# shellcheck source=tools/card-release.sh
	. "$here/card-release.sh"
else
	# shellcheck source=tools/card-release.sh
	. "$here/../tools/card-release.sh"
fi

if [ $# -ge 1 ]; then
	devs=("$GC573_SYSFS/bus/pci/devices/$1")
else
	mapfile -t devs < <(gc573_cards)
fi
[ ${#devs[@]} -gt 0 ] && [ -e "${devs[0]}" ] || { echo "no GC573"; exit 3; }
rc=0
for d in "${devs[@]}"; do
	b=$(basename "$d")
	if ! h=$(gc573_holders "$d"); then
		echo "$b: $(gc573_scan_failed)"
		exit 2
	fi
	while read -r p n; do
		[ -n "$p" ] || continue
		f=$(awk -v p="$p" '$1 == p { printf "%s%s", (k++ ? "," : ""), $2 }' <<< "$h")
		echo "$b: $n (pid $p): $f"
		rc=1
	done <<< "$(gc573_others "$h")"
done
exit $rc
