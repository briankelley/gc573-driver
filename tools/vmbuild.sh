#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Build the driver inside the dev VM against the VM's running kernel; optionally
# load/unload it, run checkpatch + sparse, or run the regression suite there.
# The module is never loaded on the host.
#
# Usage: tools/vmbuild.sh [ACTION...]
#   (none)        sync tree to the VM, clean W=1 build; any compiler warning fails
#   load          build, then (re)load gc573.ko and print the probe's dmesg
#   unload        rmmod gc573 and print its dmesg (no build)
#   check         build, then checkpatch --strict on src/ and a sparse (C=2) build
#   test [CASE..] build, then run tests/run.sh as root; log -> tests/logs/
# Env: VM (ssh alias, default gc573-dev), VMDIR (dir under the VM user's home,
#      default gc573-driver), INSMOD_ARGS (module parameters for load),
#      GC573_INPUT (HDMI input description recorded in test logs, default none)
set -euo pipefail

VM=${VM:-gc573-dev}
VMDIR=${VMDIR:-gc573-driver}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

die() { echo "vmbuild: $*" >&2; exit 1; }
vm() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$VM" "$@"; }

# Print the kernel log written after a unique marker.
kmsg_mark() { vm "echo 'gc573-vmbuild: $1' | sudo tee /dev/kmsg >/dev/null"; }
kmsg_since() { vm "sudo dmesg | awk -v m='gc573-vmbuild: $1' 'f; index(\$0, m) { f = 1 }'"; }

sync_tree() {
	rsync -a --delete \
		--exclude='*.o' --exclude='*.ko' --exclude='*.mod' --exclude='*.mod.c' \
		--exclude='.*.cmd' --exclude='modules.order' --exclude='Module.symvers' \
		--exclude='/tests/logs/' \
		--include='/Makefile' --include='/dkms.conf' \
		--include='/src/***' --include='/tests/***' --exclude='*' \
		-e "ssh -o BatchMode=yes" "$ROOT/" "$VM:$VMDIR/"
}

# Warnings the kernel tree itself causes, not the driver: the 6.8.12-gc573dbg
# headers package lacks the ubuntu/include dir its Makefile adds (W=1 reports it).
KTREE_WARN='^cc1: warning: \./ubuntu/include: No such file or directory \[-Wmissing-include-dirs\]$'

build() {
	local out
	echo "== build ($VM, $(vm uname -r))"
	vm "make -s -C $VMDIR clean >/dev/null"
	out=$(vm "make -C $VMDIR W=1 2>&1") || { echo "$out"; die "build failed"; }
	echo "$out" | grep -vE '^make(\[[0-9]+\])?: (Entering|Leaving) directory' || true
	if echo "$out" | grep -qE "$KTREE_WARN"; then
		echo "note: ignored kernel-tree warning (not driver code): missing ./ubuntu/include"
	fi
	if echo "$out" | grep -vE "$KTREE_WARN" | grep -qE 'warning:|error:'; then
		die "build has warnings"
	fi
}

check() {
	local out rc=0
	echo "== checkpatch --strict"
	vm "cd $VMDIR && /lib/modules/\$(uname -r)/build/scripts/checkpatch.pl --strict --no-tree --show-types -f src/*.[ch] Makefile" || rc=1
	echo "== sparse (C=2)"
	vm "make -s -C $VMDIR clean >/dev/null"
	out=$(vm "make -C $VMDIR C=2 2>&1") || rc=1
	echo "$out" | grep -E 'warning:|error:' && rc=1
	[ "$rc" = 0 ] && echo "sparse: clean"
	return "$rc"
}

load() {
	local tag="load-$(date +%s%N)"
	kmsg_mark "$tag"
	vm "cd $VMDIR && { sudo rmmod gc573 2>/dev/null || true; } &&
	    deps=\$(modinfo -F depends ./gc573.ko | tr , ' ') &&
	    { [ -z \"\$deps\" ] || sudo modprobe -a \$deps; } &&
	    sudo insmod ./gc573.ko ${INSMOD_ARGS:-}"
	kmsg_since "$tag"
}

unload() {
	local tag="unload-$(date +%s%N)"
	kmsg_mark "$tag"
	vm "sudo rmmod gc573"
	kmsg_since "$tag"
}

run_tests() {
	local krel stamp log rev rc=0
	krel=$(vm uname -r)
	stamp=$(date -u +%Y%m%d-%H%M%S)
	rev=$(git -C "$ROOT" describe --always --dirty --abbrev=12)
	mkdir -p "$ROOT/tests/logs"
	log="$ROOT/tests/logs/${stamp}_${krel}.log"
	vm "cd $VMDIR && sudo GC573_REV=$rev GC573_INPUT='${GC573_INPUT:-none}' tests/run.sh $*" \
		2>&1 | tee "$log" || rc=$?
	echo "log: ${log#"$ROOT"/}"
	return "$rc"
}

[ $# -gt 0 ] || set -- build
case "$1" in
unload) ;;
*) sync_tree; build ;;
esac
while [ $# -gt 0 ]; do
	case "$1" in
	build) ;;
	load) load ;;
	unload) unload ;;
	check) check ;;
	test) shift; run_tests "$@"; exit ;;
	*) die "unknown action: $1" ;;
	esac
	shift
done
