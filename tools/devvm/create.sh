#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Build dev VM `gc573-dev`: Ubuntu 24.04 / kernel 6.8, GC573 passthrough. New-driver bring-up
# and test suite run here (crash containment). Stop gc573-ref first: one VM owns the card.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
NAME=${NAME:-gc573-dev} RELEASE=noble OSINFO=ubuntu24.04 USERDATA="$HERE/user-data.in" \
  exec "$HERE/../refvm/create.sh"
