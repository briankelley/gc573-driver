#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M2 gate: v4l2-compliance -s (streaming tests included) on the capture node:
# 0 failures. Prints the version, the summary, and every warning and failure.
# SKIP when v4l2-compliance is not installed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

command -v v4l2-compliance >/dev/null || skip "v4l2-compliance not installed"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

gc573_load || fail "insmod failed"
dev=$(gc573_video_dev) || { gc573_unload; fail "no video node"; }
v4l2-compliance -d "$dev" -s > "$tmp/out" 2>&1
rc=$?
gc573_unload || fail "rmmod failed"

v4l2-compliance --version 2>&1 | head -1
grep -E 'fail|warn|Total for' "$tmp/out" | sed 's/^/  /'
summary=$(grep 'Total for' "$tmp/out")
[ -n "$summary" ] || { cat "$tmp/out"; fail "no summary (exit $rc)"; }
echo "$summary" | grep -q 'Failed: 0,' || fail "v4l2-compliance failures"
echo "exit status $rc"
