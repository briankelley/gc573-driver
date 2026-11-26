# SPDX-License-Identifier: GPL-2.0
# Sourced by the shell tools that write logs (bash). gc573_scrub TEXT...
# prints TEXT with the serial of every USB device name in it replaced by
# <serial> (tools/testsrc/scrub.py: usb-<vendor>_<model>_<serial>-...).
# Text without "usb-" is printed as it is, without starting Python.
GC573_SCRUB_PY=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scrub.py
gc573_scrub() {
	case "$*" in
	*usb-*) printf '%s\n' "$*" | python3 "$GC573_SCRUB_PY" ;;
	*) printf '%s\n' "$*" ;;
	esac
}
