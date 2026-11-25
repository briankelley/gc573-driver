#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Build tools/testsrc/place.c (the test players' window placement, see there)
# into the run directory, once per source version, and print the library's
# path. Host only. Needs cc and the X11 headers (libx11-dev).
# Usage: so=$(tools/testsrc/place.sh)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
run=${XDG_RUNTIME_DIR:-/tmp}/gc573-testsrc; mkdir -p "$run"
so=$run/place-$(sha256sum "$here/place.c" | cut -c1-16).so
if [ ! -f "$so" ]; then
  tmp=$(mktemp "$run/place.XXXXXX")
  if ! cc -O2 -Wall -Wextra -Werror -shared -fPIC -o "$tmp" "$here/place.c" -ldl -lX11 >&2; then
    rm -f "$tmp"
    echo "place.sh: cannot build $here/place.c" >&2
    exit 1
  fi
  mv "$tmp" "$so"
fi
echo "$so"
